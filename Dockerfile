FROM sonatype/nexus3:3.68.0

ARG GCS_PLUGIN_VERSION=0.0.7

USER root

RUN curl -fSL \
    "https://github.com/sonatype-nexus-community/nexus-blobstore-google-cloud/releases/download/${GCS_PLUGIN_VERSION}/nexus-blobstore-google-cloud-${GCS_PLUGIN_VERSION}.kar" \
    -o /opt/sonatype/nexus/deploy/nexus-blobstore-google-cloud.kar

USER nexus

EXPOSE 8081
