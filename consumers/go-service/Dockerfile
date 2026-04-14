FROM golang:1.24-bookworm@sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /bin/app ./cmd/go-service

FROM gcr.io/distroless/static-debian12:nonroot@sha256:c7742da01aa7ee169d59e58a91c35da9c13e67f555dcd8b2ada15887aa619e6c AS runner
COPY --from=builder /bin/app /bin/app
ENTRYPOINT ["/bin/app"]
