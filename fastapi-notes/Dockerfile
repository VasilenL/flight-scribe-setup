FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
EXPOSE 8000
# One uvicorn worker per core (Python GIL); each worker its own event loop + asyncpg pool.
# uvicorn[standard] pulls in uvloop + httptools for speed. No per-request access log.
CMD ["sh","-c","uvicorn main:app --host 0.0.0.0 --port 8000 --workers ${WEB_WORKERS:-2} --no-access-log"]
