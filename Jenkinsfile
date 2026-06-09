// CI pipeline: builds the Dockerfile in this repo and pushes the image to
// Google Artifact Registry, following the gdncomm convention.
//
// Mirrors mcp-customer-exp's app-repo Jenkinsfile. The shared library handles
// build + tag + push; this repo just declares what/where.
//
// NOTE: confirm `service_name` and the registry path with the platform team
// before first run. Keycloak is an IAM concern, so tribe/squad = iam.
@Library('jenkins-ci-automation@develop') _

BlibliPipeline([
  type: 'docker',
  docker_registry_base_image: 'asia-southeast1-docker.pkg.dev/nonprod-utility-233414/docker-releases/blibli-apps',
  application: [
    tribe: "iam",
    squad: "iam",
    service_name: "keycloak"
  ],
  sonar: [
    ignore_quality_gate: true
  ]
])
