# builder Stage
FROM golang:1.21-alpine AS builder
RUN apk add --no-cache git ca-certificates
WORKDIR /app
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o twitch-miner .

# runtime Stage
FROM alpine:latest
RUN apk --no-cache add ca-certificates tzdata
WORKDIR /app
COPY --from=builder /app/twitch-miner .
RUN mkdir -p /app/cookies /app/logs
VOLUME ["/app/cookies", "/app/logs"]
ENV CONFIG_PATH=/app/config.json
CMD ["./twitch-miner"]
