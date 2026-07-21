/*
Copyright The Platform Mesh Authors.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package controller implements the S3 vendor operator.
//
// It reconciles S3Bucket resources (s3.opendefense.internal) - the
// vendor-side API that the kro ResourceGraphDefinition in
// providers/floci-aws/manifests/rgd-bucket.yaml translates the generic
// storage.opendefense.cloud Bucket into. It plays the same role AWS ACK,
// GCP Config Connector or Azure Service Operator play for the real clouds.
//
// The reconciliation is deliberately linear and small so it can be read
// top-to-bottom:
//
//  1. resolve which configured backend ("provider") should fulfill the bucket
//  2. handle deletion (remove the bucket on the backend, drop the finalizer)
//  3. ensure the bucket exists on the backend
//  4. optionally enable server-side encryption
//  5. publish a credentials Secret next to the S3Bucket
//  6. publish the observed state in .status
//
// A provider switch (spec.provider changes) simply re-runs steps 3-6 against
// the new backend. Moving the *data* is not this operator's job - see
// the provider switch flow for the live migration flow.
package controller

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/minio/minio-go/v7/pkg/sse"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	s3v1alpha1 "github.com/platform-mesh/example-api-extraction/api/s3/v1alpha1"
	"github.com/platform-mesh/example-api-extraction/internal/provider"
)

const (
	// BucketFinalizer guards backend cleanup: the bucket on the S3
	// backend is removed before the S3Bucket resource disappears.
	BucketFinalizer = "s3.opendefense.internal/bucket-cleanup"

	// ConditionReady is the single condition type this PoC maintains.
	ConditionReady = "Ready"
)

// S3BucketReconciler reconciles S3Buckets against one or more
// S3-compatible backends from the providers file.
type S3BucketReconciler struct {
	client.Client
	Scheme    *runtime.Scheme
	Providers *provider.Config
}

// +kubebuilder:rbac:groups=s3.opendefense.internal,resources=s3buckets,verbs=get;list;watch;update;patch
// +kubebuilder:rbac:groups=s3.opendefense.internal,resources=s3buckets/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=s3.opendefense.internal,resources=s3buckets/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch;create;update;patch;delete

func (r *S3BucketReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	bucket := &s3v1alpha1.S3Bucket{}
	if err := r.Get(ctx, req.NamespacedName, bucket); err != nil {
		// Resource is gone, nothing to do.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Step 1: resolve the backend that should fulfill this bucket.
	providerName := bucket.Spec.Provider
	if providerName == "" {
		providerName = r.Providers.DefaultProvider
	}
	backend, ok := r.Providers.Providers[providerName]
	if !ok {
		// A wrong provider selection is a user error, not a transient
		// failure: surface it in the Ready condition and wait for a
		// spec update instead of retrying.
		msg := fmt.Sprintf("provider %q is not configured in the providers file", providerName)
		return ctrl.Result{}, r.setNotReady(ctx, bucket, "UnknownProvider", msg)
	}
	logger = logger.WithValues("provider", providerName, "bucket", bucket.Spec.Bucket)

	s3, err := newS3Client(backend)
	if err != nil {
		return ctrl.Result{}, r.setNotReady(ctx, bucket, "ProviderUnavailable", err.Error())
	}

	// Step 2: deletion.
	if !bucket.DeletionTimestamp.IsZero() {
		return ctrl.Result{}, r.finalize(ctx, bucket, s3)
	}
	if controllerutil.AddFinalizer(bucket, BucketFinalizer) {
		if err := r.Update(ctx, bucket); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Step 3: ensure the bucket exists on the backend.
	region := bucket.Spec.Region
	if region == "" {
		region = backend.Region
	}
	exists, err := s3.BucketExists(ctx, bucket.Spec.Bucket)
	if err != nil {
		return ctrl.Result{}, r.setNotReady(ctx, bucket, "ProviderUnavailable", err.Error())
	}
	if !exists {
		logger.Info("creating bucket on backend")
		if err := s3.MakeBucket(ctx, bucket.Spec.Bucket, minio.MakeBucketOptions{Region: region}); err != nil {
			return ctrl.Result{}, r.setNotReady(ctx, bucket, "BucketCreationFailed", err.Error())
		}
	}

	// Step 4: server-side encryption. the backend may require a KMS for SSE-S3; if
	// none is configured we report Ready=True with a warning message
	// instead of blocking the whole bucket on it.
	encryptionWarning := ""
	if bucket.Spec.SSE {
		if err := s3.SetBucketEncryption(ctx, bucket.Spec.Bucket, sse.NewConfigurationSSES3()); err != nil {
			encryptionWarning = fmt.Sprintf(" (encryption requested but rejected by backend: %v)", err)
		}
	}

	// Step 5: publish the credentials Secret next to the S3Bucket.
	// The keys follow the common AWS SDK environment variable names so
	// workloads can consume the Secret with envFrom.
	secretBase := bucket.Spec.SecretBaseName
	if secretBase == "" {
		secretBase = bucket.Name
	}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{
		Name:      secretBase + "-credentials",
		Namespace: bucket.Namespace,
	}}
	_, err = controllerutil.CreateOrUpdate(ctx, r.Client, secret, func() error {
		secret.StringData = map[string]string{
			"AWS_ACCESS_KEY_ID":         backend.AccessKey,
			"AWS_SECRET_ACCESS_KEY":     backend.SecretKey,
			"AWS_REGION":                region,
			"AWS_ENDPOINT_URL":          backend.Endpoint,
			"AWS_ENDPOINT_URL_INTERNAL": backend.InternalEndpoint,
			"BUCKET_NAME":               bucket.Spec.Bucket,
		}
		return controllerutil.SetControllerReference(bucket, secret, r.Scheme)
	})
	if err != nil {
		return ctrl.Result{}, r.setNotReady(ctx, bucket, "SecretFailed", err.Error())
	}

	// Step 6: publish the observed state.
	bucket.Status.BucketID = bucketID(bucket)
	bucket.Status.AllocatedRegion = region
	bucket.Status.Endpoint = strings.TrimSuffix(backend.Endpoint, "/") + "/" + bucket.Spec.Bucket
	bucket.Status.InternalEndpoint = backend.InternalEndpoint
	bucket.Status.SecretName = secret.Name
	bucket.Status.Provider = providerName
	meta.SetStatusCondition(&bucket.Status.Conditions, metav1.Condition{
		Type:               ConditionReady,
		Status:             metav1.ConditionTrue,
		Reason:             "BucketProvisioned",
		Message:            fmt.Sprintf("bucket %q is available on provider %q%s", bucket.Spec.Bucket, providerName, encryptionWarning),
		ObservedGeneration: bucket.Generation,
	})
	return ctrl.Result{}, r.Status().Update(ctx, bucket)
}

// finalize deletes the bucket on the backend currently selected by
// spec.provider and releases the finalizer. ForceDelete also removes any
// remaining objects - acceptable for a PoC, a real provider would refuse or
// archive instead. Note: after a migration the source backend keeps its
// (stale) copy of the bucket; the provider switch flow cleans it up explicitly.
func (r *S3BucketReconciler) finalize(ctx context.Context, bucket *s3v1alpha1.S3Bucket, s3 *minio.Client) error {
	if !controllerutil.ContainsFinalizer(bucket, BucketFinalizer) {
		return nil
	}
	exists, err := s3.BucketExists(ctx, bucket.Spec.Bucket)
	if err != nil {
		return err
	}
	if exists {
		if err := s3.RemoveBucketWithOptions(ctx, bucket.Spec.Bucket, minio.RemoveBucketOptions{ForceDelete: true}); err != nil {
			return err
		}
	}
	controllerutil.RemoveFinalizer(bucket, BucketFinalizer)
	return r.Update(ctx, bucket)
}

// setNotReady records a Ready=False condition and returns the update error,
// so callers can `return ctrl.Result{}, r.setNotReady(...)`.
func (r *S3BucketReconciler) setNotReady(ctx context.Context, bucket *s3v1alpha1.S3Bucket, reason, message string) error {
	meta.SetStatusCondition(&bucket.Status.Conditions, metav1.Condition{
		Type:               ConditionReady,
		Status:             metav1.ConditionFalse,
		Reason:             reason,
		Message:            message,
		ObservedGeneration: bucket.Generation,
	})
	return r.Status().Update(ctx, bucket)
}

// newS3Client builds a MinIO client from a backend's endpoint URL.
func newS3Client(backend provider.Backend) (*minio.Client, error) {
	u, err := url.Parse(backend.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("parsing endpoint %q: %w", backend.Endpoint, err)
	}
	return minio.New(u.Host, &minio.Options{
		Creds:  credentials.NewStaticV4(backend.AccessKey, backend.SecretKey, ""),
		Secure: u.Scheme == "https",
	})
}

// bucketID derives a stable, human-shareable identifier from the resource
// UID, e.g. "obs-e2f5g8".
func bucketID(bucket *s3v1alpha1.S3Bucket) string {
	sum := sha256.Sum256([]byte(bucket.UID))
	return "obs-" + hex.EncodeToString(sum[:])[:6]
}

// SetupWithManager registers the reconciler. The operator also watches the
// credentials Secrets it owns, so a deleted Secret is recreated.
func (r *S3BucketReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&s3v1alpha1.S3Bucket{}).
		Owns(&corev1.Secret{}).
		Named("s3bucket").
		Complete(r)
}
