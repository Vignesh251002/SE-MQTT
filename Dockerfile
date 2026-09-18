FROM eclipse-mosquitto:2.1-alpine
# Auth-enabled config + entrypoint that generates passwordfile from env vars
COPY mosquitto.auth.conf /mosquitto/config/mosquitto.conf
COPY entrypoint.sh /entrypoint.sh

# On Windows workspaces, shell scripts can accidentally get CRLF endings.
# That breaks the shebang ("/bin/sh\r"), causing: exec /entrypoint.sh: no such file or directory
RUN sed -i 's/\r$//' /entrypoint.sh \
	&& chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
