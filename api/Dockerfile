FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
# Slow/high-latency uplink: pip's 15s default read timeout aborts mid-wheel, and
# this link stalls dead for minutes. Large wheels are pre-fetched to ./wheels
# with a resumable transfer; --find-links uses those and only small packages
# come off the network.
ENV PIP_DEFAULT_TIMEOUT=180 PIP_RETRIES=10
COPY wheels/ /wheels/
# Install the pre-fetched large wheels OFFLINE first. With the index still
# enabled, --find-links alone leaves pip free to pick the identical file from
# PyPI, which is the 12.5 MB download that keeps stalling. Installing them
# first means the main resolve sees them already satisfied and skips the fetch.
#
# The wheels are optional: api/wheels/ holds only a .gitkeep in Git (the .whl
# files are ignored), so on a machine with a normal connection -- a CI runner,
# another laptop -- this step finds nothing, does nothing, and pip fetches
# everything from the index as usual.
RUN if ls /wheels/*.whl >/dev/null 2>&1; then \
      pip install --no-cache-dir --no-index --no-deps /wheels/*.whl; \
    fi
RUN pip install --no-cache-dir --find-links=/wheels -r requirements.txt

# All modules, not just app.py -- auth.py and billing.py live alongside it.
COPY *.py ./

EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
