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
	"k8s.io/apimachinery/pkg/runtime"
)

// StorageClass defines how objects in the bucket are stored and determines
// the SLA and the cost of storage.
// +kubebuilder:validation:Enum=Standard;Nearline;Coldline;Archive
type StorageClass string

const (
	StorageClassStandard StorageClass = "Standard"
	StorageClassNearline StorageClass = "Nearline"
	StorageClassColdline StorageClass = "Coldline"
	StorageClassArchive  StorageClass = "Archive"
)

// BucketSpec defines the desired state of a Bucket.
type BucketSpec struct {
	// BucketName is the name of the bucket.
	// +required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:example="my-bucket"
	BucketName string `json:"bucketName"`

	// BucketPolicy holds a provider-neutral bucket policy document.
	// +optional
	BucketPolicy *runtime.RawExtension `json:"bucketPolicy,omitempty"`

	// BucketSize defines the size (in GB) of the bucket.
	// +optional
	// +kubebuilder:default=20
	// +kubebuilder:example=50
	BucketSize int64 `json:"bucketSize,omitempty"`

	// Description of bucket contents.
	// +optional
	// +kubebuilder:example="my-bucket-for-backups"
	Description string `json:"description,omitempty"`

	// Encryption enables server-side encryption at rest.
	// +optional
	// +kubebuilder:default=false
	// +kubebuilder:example=true
	Encryption bool `json:"encryption,omitempty"`

	// Permissions holds access permission definitions for the bucket.
	// +optional
	Permissions *runtime.RawExtension `json:"permissions,omitempty"`

	// ProviderConfig holds optional, provider-specific Bucket settings.
	// It is intentionally schemaless: each provider documents the keys it
	// understands. The S3 PoC provider understands
	// {"provider": "<name>"} to select one of its configured backends,
	// which is also the switch used during a migration cutover.
	// +optional
	ProviderConfig *runtime.RawExtension `json:"providerConfig,omitempty"`

	// Region defines the region where the bucket is stored.
	// +optional
	// +kubebuilder:example="de-boe-1"
	Region string `json:"region,omitempty"`

	// StorageClass defines how objects in the bucket are stored and
	// determines the SLA and the cost of storage.
	// +optional
	// +kubebuilder:default=Standard
	StorageClass StorageClass `json:"storageClass,omitempty"`
}

// SecretRef references a Kubernetes Secret by name. The Secret lives in the
// same namespace as the referencing resource.
type SecretRef struct {
	// Name is the metadata.name of the Secret resource.
	// +required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:example="example-secret"
	Name string `json:"name"`
}

// BucketStatus defines the observed state of a Bucket, populated by the
// provider controller.
type BucketStatus struct {
	// AllocatedRegion is the region where the bucket is stored.
	// +optional
	AllocatedRegion string `json:"allocatedRegion,omitempty"`

	// BucketID is the unique identifier assigned to the bucket.
	// +optional
	// +kubebuilder:example="obs-e2f5g8"
	BucketID string `json:"bucketId,omitempty"`

	// BucketSecret references the Kubernetes Secret containing the bucket
	// credentials. The Secret lives in the same namespace as the Bucket.
	// +optional
	BucketSecret *SecretRef `json:"bucketSecret,omitempty"`

	// Conditions represent the latest available observations.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// EncryptionStatus holds the observed encryption state.
	// +optional
	EncryptionStatus *runtime.RawExtension `json:"encryptionStatus,omitempty"`

	// Endpoint is the S3-compatible endpoint URL.
	// +optional
	// +kubebuilder:example="https://my-bucket.s3.provider.io"
	Endpoint string `json:"endpoint,omitempty"`

	// ProviderStatus holds provider-specific observed state that has no
	// generic representation. The S3 PoC provider records
	// {"provider": "<name>"} here so a provider switch (migration cutover)
	// is observable.
	// +optional
	ProviderStatus *runtime.RawExtension `json:"providerStatus,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Bucket",type=string,JSONPath=`.spec.bucketName`
// +kubebuilder:printcolumn:name="Region",type=string,JSONPath=`.status.allocatedRegion`
// +kubebuilder:printcolumn:name="Endpoint",type=string,JSONPath=`.status.endpoint`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=="Ready")].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// Bucket is the Schema for the buckets API.
type Bucket struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// spec defines the desired state of the Bucket
	// +required
	Spec BucketSpec `json:"spec"`

	// status defines the observed state of the Bucket
	// +optional
	Status BucketStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BucketList contains a list of Bucket.
type BucketList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Bucket `json:"items"`
}

func init() {
	SchemeBuilder.Register(&Bucket{}, &BucketList{})
}
