FROM golang:1.22-alpine AS build
WORKDIR /src
COPY apps/signaling/go.mod apps/signaling/go.sum* ./
RUN go mod download || true
COPY apps/signaling ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/signaling ./cmd/server

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
RUN addgroup -g 10001 app && adduser -u 10001 -G app -D -s /sbin/nologin app
USER app
COPY --from=build /out/signaling /signaling
EXPOSE 8080
ENV PORT=8080
ENTRYPOINT ["/signaling"]
