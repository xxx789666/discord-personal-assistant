import json
import sys
from pathlib import Path

import pytest

SPACE_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SPACE_ROOT / "tools"))

FIXTURE = SPACE_ROOT / "fixtures" / "sample_report.json"


@pytest.fixture
def sample_data():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))
