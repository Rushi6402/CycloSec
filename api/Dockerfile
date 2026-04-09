FROM python:3.11-slim

WORKDIR /app

<<<<<<< HEAD
=======
# Install curl for healthcheck
>>>>>>> d350c45 (add the api file)
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
