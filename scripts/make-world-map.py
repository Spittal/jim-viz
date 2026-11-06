#!/usr/bin/env python3
"""Builds Content/Maps/world.json, the Globe geo's map of countries.

Usage: scripts/make-world-map.py countries-50m.json

The input is world-atlas's TopoJSON of Natural Earth's 1:50m countries (public domain data):
https://cdn.jsdelivr.net/npm/world-atlas@2/countries-50m.json
Neighbouring countries share their border lines (arcs) there, which is what lets the Globe
simplify the map without the countries coming apart.

Output:
  "arcs": border and coast lines, each a flat [lon, lat, lon, lat, …] in degrees. Longitude
          runs on past ±180 where a line crosses the antimeridian, so it never jumps.
  "countries": per country, its polygons; per polygon, its rings (the outline, then any
          holes); per ring, its arcs in order, ~index for an arc taken backwards.
"""
import json, os, sys

topo = json.load(open(sys.argv[1]))
sx, sy = topo["transform"]["scale"]
tx, ty = topo["transform"]["translate"]

arcs = []
for arc in topo["arcs"]:
    x = y = 0
    flat = []
    for dx, dy in arc:
        x += dx; y += dy
        lon, lat = x * sx + tx, y * sy + ty
        if flat:
            while lon - flat[-2] > 180: lon -= 360
            while lon - flat[-2] < -180: lon += 360
        p = [round(lon, 2), round(lat, 2)]
        if flat[-2:] != p or len(arc) == 2: flat += p
    if len(flat) == 2: flat += flat
    arcs.append(flat)

countries = []
for g in topo["objects"]["countries"]["geometries"]:
    countries.append([g["arcs"]] if g["type"] == "Polygon" else g["arcs"])

dest = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Content", "Maps", "world.json")
with open(dest, "w") as f:
    json.dump({"arcs": arcs, "countries": countries}, f, separators=(",", ":"))
print(dest, len(countries), "countries,", len(arcs), "arcs,", sum(len(a) // 2 for a in arcs), "points")
