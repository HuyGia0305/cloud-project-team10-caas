FROM python:3.12.15-alpine

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app app

COPY --chown=app:app app.py .
USER 10001:10001

EXPOSE 8080
CMD ["python", "app.py"]