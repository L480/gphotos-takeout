FROM rclone/rclone:1.69

# Add a small shell script runner.
COPY scripts/run-sync.sh /usr/local/bin/run-sync.sh
RUN chmod +x /usr/local/bin/run-sync.sh

ENTRYPOINT ["/usr/local/bin/run-sync.sh"]
