"""Regenerate every deliverable of the 'Cozy pastel diorama' style:
city_600.png, closeup_2x.png (make_city.py) and tiers.png (make_tiers.py).
Requires: pip install pillow numpy shapely
"""
import make_city, make_tiers

if __name__ == "__main__":
    make_city.main()
    make_tiers.main()
