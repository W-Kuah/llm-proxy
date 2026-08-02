# Use the multi-arch image directly - works for both x86_64 and arm64
FROM public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 AS adapter

# Main LiteLLM image
FROM ghcr.io/berriai/litellm:main-latest

# Copy your model configuration
COPY config.yaml /app/config.yaml

# Copy the adapter binary
COPY --from=adapter /lambda-adapter /opt/extensions/lambda-adapter

# Tell the adapter which port LiteLLM listens on
ENV PORT=8080

# Set explicit entrypoint and command
ENTRYPOINT ["litellm"]
CMD ["--config", "/app/config.yaml", "--port", "8080"]