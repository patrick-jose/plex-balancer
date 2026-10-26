import json
from pathlib import Path

state_path = Path(__file__).resolve().parent / "playlist-data" / "state.json"
with state_path.open(encoding="utf-8") as stream:
    state = json.load(stream)

for position, item in enumerate(state["Queue"], start=1):
    if item["Type"] == "episode":
        print(
            f"{position:3d}. {item['Show']} "
            f"S{item['Season']:02d}E{item['Episode']:02d} - {item['Title']}"
        )
