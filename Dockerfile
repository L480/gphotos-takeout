FROM rclone/rclone:1.69

# Add a small shell script runner.
COPY scripts/run-sync.sh /usr/local/bin/run-sync.sh
RUN chmod +x /usr/local/bin/run-sync.sh

# Ensure the container runs as a non-root user.
USER 1000:1000

ENTRYPOINT ["/usr/local/bin/run-sync.sh"]
