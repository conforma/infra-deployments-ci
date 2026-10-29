Feature: Validate Golden Container/RPM with Retained CLI and Candidate Policy
  Validate that the retained CLI and candidate release policy work correctly
  against the golden container image and golden RPM.

  Background:
    Given a cluster running
    And the conforma pipeline using task bundle "quay.io/conforma/tekton-task@sha256:e2ac3444a229ce1688c96692ba2af166656be9313ac5cba750cac1c7daf3371d"

  Scenario: Pipeline runs to completion with golden container and @redhat collection
    Given a working namespace
    And a policy configuration with content:
      """
      {
        "sources": [
          {
            "policy": ["oci::quay.io/conforma/release-policy@sha256:c5f849046794ca55c52f5d84b88e53858b299b759fa8a4827f6911dead422315"],
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


  Scenario: Pipeline runs to completion with golden RPM and @redhat_rpms collection
    Given a working namespace
    And a policy configuration with content:
      """
      {
        "sources": [
          {
            "policy": ["oci::quay.io/conforma/release-policy@sha256:c5f849046794ca55c52f5d84b88e53858b299b759fa8a4827f6911dead422315"],
            "data": [
              "git::github.com/release-engineering/rhtap-ec-policy//data",
              "oci::quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles:latest"
            ],
            "config": {
              "include": ["@redhat_rpms"]
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
