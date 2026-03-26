FROM public.ecr.aws/docker/library/alpine:3.19

RUN apk add --no-cache socat iproute2

COPY dstack-util /app/dstack-util
RUN chmod +x /app/dstack-util

COPY root_ca.pem /app/root_ca.pem

COPY entrypoint.sh /app/run.sh
RUN chmod +x /app/run.sh

ENTRYPOINT ["/app/run.sh"]
