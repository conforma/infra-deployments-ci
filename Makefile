# Copyright The Conforma Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

.PHONY: acceptance
acceptance:
	cd acceptance && go test -v -timeout 30m ./...

.PHONY: acceptance-persist
acceptance-persist:
	cd acceptance && go test -v -timeout 30m ./... -args -persist

.PHONY: acceptance-kubeconfig
acceptance-kubeconfig: ## Export KUBECONFIG for the acceptance cluster (use with: eval $$(make acceptance-kubeconfig))
	@CLUSTER=$$(kind get clusters 2>/dev/null | grep '^acceptance-' | head -1); \
	if [ -n "$$CLUSTER" ]; then \
		kind get kubeconfig --name $$CLUSTER > /tmp/acceptance-kubeconfig 2>/dev/null; \
		echo "export KUBECONFIG=/tmp/acceptance-kubeconfig"; \
	else \
		echo "echo 'No acceptance cluster found. Run make acceptance-persist first.'"; \
	fi
