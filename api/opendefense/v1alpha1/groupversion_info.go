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

// Package v1alpha1 contains the consumer-facing, provider-neutral object
// storage API.
//
// The API group is storage.opendefense.cloud. Consumers order a Bucket and a
// provider controller (for this PoC: the S3 operator in cmd/ and internal/controller/, backed by the floci-aws emulator)
// fulfills it. The same spec could be fulfilled by GCP, AWS, Azure or any
// S3-compatible provider - that is the whole point of the API extraction: the
// consumer never talks to a vendor API directly.
//
// +kubebuilder:object:generate=true
// +groupName=storage.opendefense.cloud
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "storage.opendefense.cloud", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
