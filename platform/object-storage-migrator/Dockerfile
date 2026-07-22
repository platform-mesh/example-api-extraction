FROM rclone/rclone:1.74

COPY copy-objects.sh /usr/local/bin/copy-objects.sh
RUN chmod +x /usr/local/bin/copy-objects.sh

# overwrite the entrypoint
ENTRYPOINT ["/usr/local/bin/copy-objects.sh"]
