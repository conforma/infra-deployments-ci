Feature: Validate Golden Container/RPM with Latest CLI and Policies
  Validate that the latest CLI and release policies work correctly
  against the golden container image and golden RPM.

  Background:
    Given a cluster running
    And the conforma pipeline using task bundle "quay.io/conforma/tekton-task:latest"

  Scenario: Pipeline runs to completion with golden container and @redhat collection
    Given a working namespace
    And a policy configuration with content:
      """
      {
        "sources": [
          {
            "policy": ["oci::quay.io/conforma/release-policy:latest"],
            "data": [
              "git::github.com/release-engineering/rhtap-ec-policy//data",
              "oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest"
            ],
            "config": {
              "include": ["@redhat"]
            }
          }
        ]
      }
      """
    When the conforma pipeline is run with:
      | SNAPSHOT             | {"components": [{"containerImage": "quay.io/konflux-ci/ec-golden-image:latest"}]} |
      | POLICY_CONFIGURATION | ${NAMESPACE}/${POLICY_NAME}                                                        |
      | PUBLIC_KEY           | k8s://${NAMESPACE}/public-key                                                      |
      | STRICT               | false                                                                              |
    Then the pipeline should succeed


  Scenario: Pipeline runs to completion with golden RPM, @redhat and @redhat_rpms collections
    Given a working namespace
    And a policy configuration with content:
      """
      {
        "sources": [
          {
            "policy": ["oci::quay.io/conforma/release-policy:latest"],
            "data": [
              "git::github.com/release-engineering/rhtap-ec-policy//data",
              "oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest"
            ],
            "config": {
              "include": ["@redhat","@redhat_rpms"]
            }
          }
        ]
      }
      """
    When the conforma pipeline is run with:
      | SNAPSHOT             | {"components": [{"containerImage": "quay.io/redhat-user-workloads/rhtap-contract-tenant/golden-rpm/golden-rpm:latest"}]} |
      | POLICY_CONFIGURATION | ${NAMESPACE}/${POLICY_NAME}                                                        |
      | PUBLIC_KEY           | k8s://${NAMESPACE}/public-key                                                      |
      | STRICT               | false                                                                              |
    Then the pipeline should succeed
