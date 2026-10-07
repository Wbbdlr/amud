FROM python:3.13-slim
WORKDIR /app
COPY server.py .
RUN mkdir /data && useradd --system sync && chown sync /data
USER sync
EXPOSE 8080
CMD ["python", "server.py"]
