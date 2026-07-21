## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
CONTROLLER_TOOLS_VERSION ?= v0.17.2
.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN)
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: codegen
codegen: generate

.PHONY: generate
generate: controller-gen
	$(CONTROLLER_GEN) object paths="./api/..."
	$(CONTROLLER_GEN) crd rbac:roleName=example output:crd:dir=config/generic/crd output:rbac:dir=config/generic/rbac paths="./api/storage/..."

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef

## ---------------------------------------------------------------------------
## Workflow targets for the simple-bucket example (see hack/run.bash;
## `task <name>` from Taskfile.yml is equivalent).
.PHONY: run-all translation setup provider example status crossplane \
        rgd-gcp rgd-s3 provider-gcp provider-gcp-setup provider-gcp-example \
        provider-gcp-translation forward cleanup destroy build

run-all: ; ./hack/run.bash all
translation: ; ./hack/run.bash translation
setup: ; ./hack/run.bash setup
provider: ; ./hack/run.bash provider
example: ; ./hack/run.bash example
status: ; ./hack/run.bash status
crossplane: ; ./hack/run.bash crossplane
rgd-gcp: ; ./hack/run.bash rgd:gcp
rgd-s3: ; ./hack/run.bash rgd:s3
provider-gcp: ; ./hack/run.bash provider-gcp
provider-gcp-setup: ; ./hack/run.bash provider-gcp:setup
provider-gcp-example: ; ./hack/run.bash provider-gcp:example
provider-gcp-translation: ; ./hack/run.bash provider-gcp:translation
forward: ; ./hack/run.bash forward
cleanup: ; ./hack/run.bash cleanup
destroy: ; ./hack/run.bash destroy

build:
	cd api && go build ./... && go vet ./...
	go build ./... && go vet ./...
