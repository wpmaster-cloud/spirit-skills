#!/usr/bin/env python3
"""Fetch an RSS/Atom feed and emit only items not seen before.

Stateful poll helper for the rss-monitor skill: remembers item ids per feed under
a state dir so each item surfaces exactly once across runs (like the telegram
skill's offset memory). Pure standard library — no pip installs.

Usage:
  feed.py URL [--json] [--all] [--peek] [--reset] [--limit N] [--state DIR]
"""
import sys
import os
import json
import hashlib
import argparse
import urllib.request
import xml.etree.ElementTree as ET


def strip_ns(tag):
    """Drop an XML namespace: '{http://www.w3.org/2005/Atom}entry' -> 'entry'."""
    return tag.rsplit('}', 1)[-1]


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'spirit-rss-monitor/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def parse(data):
    root = ET.fromstring(data)
    items = []
    for el in root.iter():
        if strip_ns(el.tag) not in ('item', 'entry'):
            continue
        d = {}
        for c in el:
            t = strip_ns(c.tag)
            if t == 'link':
                # RSS uses element text; Atom uses an href attribute.
                href = c.get('href')
                val = href if href else (c.text or '').strip()
                # Prefer the canonical/alternate link if several are present.
                if 'link' not in d or c.get('rel') in (None, 'alternate'):
                    d['link'] = val
            elif t in ('title', 'guid', 'id', 'pubDate', 'published', 'updated', 'summary', 'description'):
                d[t] = (c.text or '').strip()
        items.append(d)
    return items


def item_id(d):
    for k in ('guid', 'id', 'link', 'title'):
        if d.get(k):
            return d[k]
    return hashlib.sha1(json.dumps(d, sort_keys=True).encode()).hexdigest()


def item_date(d):
    return d.get('pubDate') or d.get('published') or d.get('updated') or ''


def item_summary(d):
    return d.get('summary') or d.get('description') or ''


def main():
    ap = argparse.ArgumentParser(description='Emit new RSS/Atom feed items.')
    ap.add_argument('url')
    ap.add_argument('--state', default='rss/state', help='state dir (default: rss/state)')
    ap.add_argument('--json', action='store_true', help='JSON output instead of TSV')
    ap.add_argument('--all', action='store_true', help='ignore memory; emit everything, persist nothing')
    ap.add_argument('--peek', action='store_true', help="emit new items but don't mark them seen")
    ap.add_argument('--reset', action='store_true', help='clear this feed\'s memory and exit')
    ap.add_argument('--limit', type=int, default=0, help='cap items emitted this run')
    args = ap.parse_args()

    os.makedirs(args.state, exist_ok=True)
    key = hashlib.sha1(args.url.encode()).hexdigest()[:16]
    statefile = os.path.join(args.state, key + '.json')

    if args.reset:
        if os.path.exists(statefile):
            os.remove(statefile)
        print('reset ' + args.url, file=sys.stderr)
        return

    seen = set()
    if os.path.exists(statefile) and not args.all:
        try:
            seen = set(json.load(open(statefile)).get('seen', []))
        except Exception:
            seen = set()

    try:
        items = parse(fetch(args.url))
    except Exception as e:
        print('feed.py: %s: %s' % (args.url, e), file=sys.stderr)
        sys.exit(1)

    fresh = items if args.all else [d for d in items if item_id(d) not in seen]
    if args.limit > 0:
        fresh = fresh[:args.limit]

    if args.json:
        out = [{'id': item_id(d), 'title': d.get('title', ''), 'link': d.get('link', ''),
                'date': item_date(d), 'summary': item_summary(d)} for d in fresh]
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        for d in fresh:
            print('%s\t%s\t%s' % (item_date(d), d.get('title', '(no title)'), d.get('link', '')))

    # Persist seen-marks unless we were only peeking or dumping everything.
    if not args.peek and not args.all:
        all_ids = list(seen) + [item_id(d) for d in items]
        json.dump({'seen': all_ids[-2000:]}, open(statefile, 'w'))


if __name__ == '__main__':
    main()
