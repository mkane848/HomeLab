# The allowlist proxy for the planner container (squid.conf holds the list).
FROM alpine:3.20
RUN apk add --no-cache squid
COPY squid.conf /etc/squid/squid.conf
USER squid
EXPOSE 3128
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
