FROM golang:1.26-alpine AS launcher
COPY docker/launcher.go /src/launcher.go
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /launcher /src/launcher.go

FROM python:3.12-alpine
RUN apk add --no-cache openssl
COPY docker/prepare-runtime.py /usr/local/bin/prepare-runtime.py
COPY --from=launcher /launcher /usr/local/bin/dlc-launcher
ENTRYPOINT ["python3", "/usr/local/bin/prepare-runtime.py"]
