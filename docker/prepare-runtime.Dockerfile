FROM python:3.12-alpine
RUN apk add --no-cache openssl
COPY docker/prepare-runtime.py /usr/local/bin/prepare-runtime.py
ENTRYPOINT ["python3", "/usr/local/bin/prepare-runtime.py"]
