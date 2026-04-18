FROM golang:1.26.2-alpine3.22@sha256:6ebcc4eb3726dd548c71ad97fc8c9ab7f6d60a45fbfb7c6b734ec0489fa25c41 AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /bin/app ./cmd/go-service

FROM gcr.io/distroless/static-debian12:nonroot@sha256:a9329520abc449e3b14d5bc3a6ffae065bdde0f02667fa10880c49b35c109fd1 AS runner
COPY --from=builder /bin/app /bin/app
ENTRYPOINT ["/bin/app"]
