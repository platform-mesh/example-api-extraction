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

// Package provider holds the static configuration of the S3-compatible
// backends this controller can provision buckets on.
//
// In a production setup this would be its own CRD (compare AcceptAPI in
// platform-mesh/resource-broker). For the PoC a plain YAML file keeps the
// moving parts to a minimum and makes the setup reproducible without any
// extra APIs.
package provider

import (
	"fmt"
	"os"

	"sigs.k8s.io/yaml"
)

// Backend describes one S3-compatible provider the controller can talk to.
type Backend struct {
	// Endpoint is the S3 endpoint reachable from where the controller
	// process runs. In the PoC the controller runs on the developer
	// machine and reaches the backend through a kubectl port-forward,
	// e.g. http://127.0.0.1:4566.
	Endpoint string `json:"endpoint"`

	// InternalEndpoint is the S3 endpoint reachable from inside the
	// compute cluster, e.g. http://floci-aws.floci-aws.svc.cluster.local:4566.
	// It is written into the credentials Secret so that in-cluster
	// workloads (like the migration Jobs) can use it.
	InternalEndpoint string `json:"internalEndpoint"`

	// AccessKey and SecretKey are the credentials used both to manage
	// buckets and, for the PoC, handed out to consumers in the
	// credentials Secret. A real provider would mint per-bucket
	// credentials instead.
	AccessKey string `json:"accessKey"`
	SecretKey string `json:"secretKey"`

	// Region reported for buckets on this backend when the Bucket spec
	// does not request a specific region.
	Region string `json:"region"`
}

// Config is the top-level structure of the --providers-file.
type Config struct {
	// DefaultProvider fulfills Buckets that do not select a provider
	// explicitly via spec.providerConfig.provider.
	DefaultProvider string `json:"defaultProvider"`

	// Providers maps a provider name to its backend configuration.
	Providers map[string]Backend `json:"providers"`
}

// Load reads and validates the providers file.
func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading providers file: %w", err)
	}
	cfg := &Config{}
	if err := yaml.UnmarshalStrict(raw, cfg); err != nil {
		return nil, fmt.Errorf("parsing providers file %s: %w", path, err)
	}
	if cfg.DefaultProvider == "" {
		return nil, fmt.Errorf("providers file %s: defaultProvider must be set", path)
	}
	if _, ok := cfg.Providers[cfg.DefaultProvider]; !ok {
		return nil, fmt.Errorf("providers file %s: defaultProvider %q is not defined under providers", path, cfg.DefaultProvider)
	}
	for name, backend := range cfg.Providers {
		if backend.Endpoint == "" {
			return nil, fmt.Errorf("providers file %s: provider %q: endpoint must be set", path, name)
		}
		if backend.AccessKey == "" || backend.SecretKey == "" {
			return nil, fmt.Errorf("providers file %s: provider %q: accessKey and secretKey must be set", path, name)
		}
	}
	return cfg, nil
}
