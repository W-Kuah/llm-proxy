# Use the multi-arch image directly - works for both x86_64 and arm64
FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 AS adapter

# Main LiteLLM image, pinned to the verified digest (litellm 1.96.0, 2026-08-02)
# Bump deliberately after testing a new image.
FROM ghcr.io/berriai/litellm:main-latest@sha256:be646214d7bc1cda0be57debbbf58e822ca4f233ddc50d0c0c7fa9b4a28063af

# Copy your model configuration
COPY config.yaml /app/config.yaml

# Copy the adapter binary
COPY --from=adapter /lambda-adapter /opt/extensions/lambda-adapter

# Tell the adapter which port LiteLLM listens on
ENV PORT=8080

# Set explicit entrypoint and command
ENTRYPOINT ["litellm"]
CMD ["--config", "/app/config.yaml", "--port", "8080"]