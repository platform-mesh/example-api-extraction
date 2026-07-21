/*
Copyright The Platform Mesh Authors.

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

// ObjectStorageSpec defines the desired state of ObjectStorage.
type ObjectStorageSpec struct {
	// Region is the geographic region where the object storage should be created.
	// The resource-broker routes the order to a provider that accepts this region.
	// +optional
	Region string `json:"region,omitempty"`

	// Versioning enables object versioning.
	// +optional
	Versioning bool `json:"versioning,omitempty"`
}

// GroupVersionKind unambiguously identifies a kind.
type GroupVersionKind struct {
	Group   string `json:"group"`
	Version string `json:"version"`
	Kind    string `json:"kind"`
}

type RelatedResource struct {
	GVK  GroupVersionKind `json:"gvk"`
	Name string           `json:"name"`
	// +optional
	Namespace string `json:"namespace,omitempty"`
}

// ObjectStorageStatus defines the observed state of ObjectStorage.
type ObjectStorageStatus struct {
	// Status is a human-readable provisioning state (e.g. Provisioning, Available), set by the realizing provider.
	// +optional
	Status string `json:"status,omitempty"`

	// URL is the address of the provisioned object storage (e.g. gs://bucket or s3://bucket), set by the realizing provider.
	// +optional
	URL string `json:"url,omitempty"`

	// Conditions represent the latest available observations of the ObjectStorage's state.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// RelatedResources lists resources related to this ObjectStorage, keyed by identifier.
	// The resource-broker copies these (e.g. a result Secret) back to the consumer.
	// +optional
	RelatedResources map[string]RelatedResource `json:"relatedResources,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Region",type=string,JSONPath=`.spec.region`
// +kubebuilder:printcolumn:name="Status",type=string,JSONPath=`.status.status`
// +kubebuilder:printcolumn:name="URL",type=string,JSONPath=`.status.url`

// ObjectStorage is the Schema for the ObjectStorage.
type ObjectStorage struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ObjectStorageSpec   `json:"spec,omitempty"`
	Status ObjectStorageStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// ObjectStorageList contains a list of ObjectStorage.
type ObjectStorageList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ObjectStorage `json:"items"`
}
