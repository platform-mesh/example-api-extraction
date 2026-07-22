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

package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// S3BucketSpec defines the desired state of a bucket on one of the MinIO
// backends configured in the operator's providers file.
//
// The field names are deliberately vendor-shaped (compare the AWS ACK Bucket
// or GCP StorageBucket specs) and NOT identical to the generic
// storage.opendefense.cloud Bucket: mapping between the two is the job of
// the kro ResourceGraphDefinition in providers/floci-aws/manifests/rgd-bucket.yaml.
type S3BucketSpec struct {
	// Bucket is the name of the S3 bucket to create.
	// +required
	// +kubebuilder:validation:MinLength=1
	Bucket string `json:"bucket"`

	// Region to create the bucket in. Falls back to the provider's
	// configured default region when empty.
	// +optional
	Region string `json:"region,omitempty"`

	// SSE enables server-side encryption for the bucket. Requires a KMS
	// to be configured on the backend; if that is missing the
	// operator reports the failure in the conditions but keeps the
	// bucket usable.
	// +optional
	SSE bool `json:"sse,omitempty"`

	// Provider selects which backend from the operator's providers file
	// fulfills this bucket. Falls back to the configured default
	// provider when empty. Changing this field is the migration cutover:
	// the operator provisions the bucket on the new backend and repoints
	// the credentials Secret - it does NOT move data (see
	// hack/migrate.bash).
	// +optional
	Provider string `json:"provider,omitempty"`

	// SecretBaseName overrides the base name of the credentials Secret
	// the operator maintains ("<base>-credentials", default base is
	// metadata.name). The kro translation sets this to the consumer-side
	// resource name so that the Secret synced back into the kcp
	// workspace carries a predictable name.
	// +optional
	SecretBaseName string `json:"secretBaseName,omitempty"`
}

// S3BucketStatus defines the observed state of a S3Bucket.
type S3BucketStatus struct {
	// BucketID is the unique identifier assigned to the bucket.
	// +optional
	BucketID string `json:"bucketId,omitempty"`

	// AllocatedRegion is the region the bucket was created in.
	// +optional
	AllocatedRegion string `json:"allocatedRegion,omitempty"`

	// Endpoint is the S3 URL of the bucket as reachable from the
	// developer machine (through the port-forward).
	// +optional
	Endpoint string `json:"endpoint,omitempty"`

	// InternalEndpoint is the S3 URL of the backend as reachable from
	// inside the compute cluster.
	// +optional
	InternalEndpoint string `json:"internalEndpoint,omitempty"`

	// SecretName is the name of the credentials Secret maintained next
	// to this S3Bucket.
	// +optional
	SecretName string `json:"secretName,omitempty"`

	// Provider is the backend currently fulfilling this bucket.
	// +optional
	Provider string `json:"provider,omitempty"`

	// Conditions represent the latest available observations.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Bucket",type=string,JSONPath=`.spec.bucket`
// +kubebuilder:printcolumn:name="Provider",type=string,JSONPath=`.status.provider`
// +kubebuilder:printcolumn:name="Endpoint",type=string,JSONPath=`.status.endpoint`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// S3Bucket is the Schema for the s3buckets API.
type S3Bucket struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// spec defines the desired state of the S3Bucket
	// +required
	Spec S3BucketSpec `json:"spec"`

	// status defines the observed state of the S3Bucket
	// +optional
	Status S3BucketStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// S3BucketList contains a list of S3Bucket.
type S3BucketList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []S3Bucket `json:"items"`
}

func init() {
	SchemeBuilder.Register(&S3Bucket{}, &S3BucketList{})
}
