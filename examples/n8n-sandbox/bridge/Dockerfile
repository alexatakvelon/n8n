FROM python:3.11-slim

WORKDIR /app

COPY requirements.in requirements.in

RUN pip install --no-cache-dir \
    $(grep -v '^#' requirements.in | tr '\n' ' ')

COPY main.py .

RUN chown -R 1000:1000 /app
USER 1000

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
