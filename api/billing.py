"""Mock billing. TEST MODE ONLY -- no money moves, no card data is accepted.

Plans grant a credit allowance and a set of stem counts. One separation costs
one credit. `checkout` is a simulation: it takes a plan name, records a fake
payment and grants the credits. There is deliberately no card form, no payment
provider, and no receipt that could be mistaken for a real one.
"""

PLANS = {
    "free": {
        "name": "Free",
        "price_usd": 0,
        "credits": 3,
        "stems": [2],
        "blurb": "3 separations. Vocals + accompaniment only.",
    },
    "pro": {
        "name": "Pro",
        "price_usd": 9,
        "credits": 50,
        "stems": [2, 4, 5],
        "blurb": "50 separations. Unlocks 4-stem and 5-stem models.",
    },
    "studio": {
        "name": "Studio",
        "price_usd": 29,
        "credits": 200,
        "stems": [2, 4, 5],
        "blurb": "200 separations. All models.",
    },
}

DEFAULT_PLAN = "free"


def plan_of(name):
    return PLANS.get(name or DEFAULT_PLAN, PLANS[DEFAULT_PLAN])


def stems_allowed(plan_name, stems):
    return int(stems) in plan_of(plan_name)["stems"]
