"""
Generates fake campus canteen orders as CSV files, one file per day.

The data is a little messy on purpose, just like real data:
  - some item names have extra spaces or random CAPS
  - some rows are exact duplicates
  - some orders have a blank payment mode
  - some orders have quantity 0 (cancelled orders)

Our AWS Glue job will clean all of this up.

Run:  python3 generate_orders.py
"""

import csv
import random
from datetime import datetime, timedelta
from pathlib import Path

random.seed(2026)

MENU = {
    # item: (category, price in INR)
    "Vada Pav": ("Snacks", 20),
    "Samosa": ("Snacks", 15),
    "Dabeli": ("Snacks", 25),
    "Surti Locho": ("Snacks", 40),
    "Khaman": ("Snacks", 30),
    "Veg Puff": ("Snacks", 25),
    "Masala Dosa": ("Meals", 60),
    "Pav Bhaji": ("Meals", 70),
    "Veg Frankie": ("Meals", 50),
    "Cheese Sandwich": ("Meals", 45),
    "Maggi": ("Meals", 40),
    "Cutting Chai": ("Drinks", 10),
    "Cold Coffee": ("Drinks", 50),
    "Lassi": ("Drinks", 35),
}

# How popular each item is (bigger number = ordered more often)
POPULARITY = {
    "Vada Pav": 18, "Samosa": 12, "Dabeli": 8, "Surti Locho": 7, "Khaman": 6,
    "Veg Puff": 6, "Masala Dosa": 7, "Pav Bhaji": 5, "Veg Frankie": 6,
    "Cheese Sandwich": 6, "Maggi": 10, "Cutting Chai": 20, "Cold Coffee": 11,
    "Lassi": 4,
}

PAYMENT_MODES = ["UPI", "Cash", "Card"]
PAYMENT_WEIGHTS = [75, 20, 5]
COUNTERS = ["Main Canteen", "Library Cafe", "Hostel Mess"]
COUNTER_WEIGHTS = [60, 25, 15]

# Rush hours: short break, lunch, evening snacks
HOUR_WEIGHTS = {8: 3, 9: 6, 10: 9, 11: 14, 12: 10, 13: 16, 14: 9, 15: 7, 16: 12, 17: 8, 18: 4}

START_DATE = datetime(2026, 11, 16)  # Monday
DAYS = 5
ORDERS_PER_DAY = (520, 680)

OUT_DIR = Path(__file__).parent / "raw" / "orders"


def messy_name(name: str) -> str:
    """Make an item name messy now and then, like a hurried cashier would."""
    r = random.random()
    if r < 0.04:
        return name.upper()
    if r < 0.08:
        return name.lower()
    if r < 0.11:
        return "  " + name + " "
    return name


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    items = list(MENU)
    weights = [POPULARITY[i] for i in items]
    hours = list(HOUR_WEIGHTS)
    hour_weights = list(HOUR_WEIGHTS.values())
    order_no = 100000
    total_rows = 0

    for d in range(DAYS):
        day = START_DATE + timedelta(days=d)
        rows = []
        for _ in range(random.randint(*ORDERS_PER_DAY)):
            order_no += 1
            item = random.choices(items, weights)[0]
            category, price = MENU[item]
            hour = random.choices(hours, hour_weights)[0]
            ts = day.replace(hour=hour, minute=random.randint(0, 59), second=random.randint(0, 59))
            qty = random.choices([1, 2, 3, 4], [70, 20, 7, 3])[0]
            if random.random() < 0.02:
                qty = 0  # cancelled order
            payment = random.choices(PAYMENT_MODES, PAYMENT_WEIGHTS)[0]
            if random.random() < 0.03:
                payment = ""  # cashier forgot to record it
            row = {
                "order_id": f"ORD{order_no}",
                "order_time": ts.strftime("%Y-%m-%d %H:%M:%S"),
                "student_id": f"STU{random.randint(1, 1500):04d}",
                "item": messy_name(item),
                "category": category,
                "quantity": qty,
                "unit_price": price,
                "payment_mode": payment,
                "counter": random.choices(COUNTERS, COUNTER_WEIGHTS)[0],
            }
            rows.append(row)
            if random.random() < 0.02:
                rows.append(dict(row))  # duplicate row (double scan at the counter)

        rows.sort(key=lambda r: r["order_time"])
        path = OUT_DIR / f"orders_{day:%Y-%m-%d}.csv"
        with path.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        total_rows += len(rows)
        print(f"wrote {len(rows):>4} rows -> {path.name}")

    print(f"done: {total_rows} rows across {DAYS} files")


if __name__ == "__main__":
    main()
