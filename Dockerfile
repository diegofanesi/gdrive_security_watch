FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY drive_permission_sweeper.py docker_oauth.py ./

CMD ["python", "drive_permission_sweeper.py", "--help"]
