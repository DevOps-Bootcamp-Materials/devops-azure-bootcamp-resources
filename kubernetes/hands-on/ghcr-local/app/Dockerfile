FROM nginx:1.27-alpine

# The OCI source label links the package to its repository on GitHub:
# the package page shows the repo, and access can be managed together.
LABEL org.opencontainers.image.source="https://github.com/YOUR_USER/hello-ghcr"
LABEL org.opencontainers.image.description="Bootcamp GHCR hands-on sample"

COPY index.html /usr/share/nginx/html/index.html
