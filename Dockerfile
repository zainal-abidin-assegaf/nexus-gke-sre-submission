# Start from the official Nexus 3 image
FROM sonatype/nexus3:3.68.0

# Switch to root to install the plugin
USER root

# Plugin version - update this when a new version is released
ARG GCS_PLUGIN_VERSION=0.0.7

# Download the GCS Blob Store plugin (.kar file) into Nexus's deploy directory
# The plugin is automatically picked up by Nexus on startup
RUN curl -fSL \
    "https://github.com/sonatype-nexus-community/nexus-blobstore-google-cloud/releases/download/${GCS_PLUGIN_VERSION}/nexus-blobstore-google-cloud-${GCS_PLUGIN_VERSION}.kar" \
    -o /opt/sonatype/nexus/deploy/nexus-blobstore-google-cloud.kar

# Switch back to the nexus user for security
USER nexus

# Nexus listens on 8081 by default
EXPOSE 8081

# Default entrypoint from the base image handles startup
