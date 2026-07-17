---
name: ui-ux-pro-max
description: AI-powered design intelligence — search 84 UI styles, 160 color palettes, 73 font pairings, 25 chart types, 161 product types, and 98 UX guidelines. Pure Python 3, no pip installs.
requires: python3
trigger-phrase: design ui, design ux, color palette, font pairing, ui style, choose a style, design system, dashboard design, landing page design, chart recommendation
---

# UI/UX Pro Max Skill

Searchable databases of UI styles, color palettes, typography, UX guidelines, and chart recommendations. Uses a BM25 + regex hybrid search engine. **No external dependencies — pure Python 3.**

Source: [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) (MIT)

## Quick reference

```bash
SKILL=skills/ui-ux-pro-max

# Search by domain (explicit)
python3 $SKILL/scripts/search.py "query" --domain <domain> -n <results>

# Auto-detect domain from query
python3 $SKILL/scripts/search.py "query"
```

## Domains

| Domain | What it searches | Best for |
|--------|-----------------|----------|
| `style` | 84 UI styles (glassmorphism, bento grid, brutalism…) | "what style fits a SaaS app?" |
| `color` | 160 palettes by product category | "color palette for fintech" |
| `typography` | 73 font pairings with Google Fonts imports | "font for a luxury brand" |
| `chart` | 25 chart types + library recommendations | "which chart for time-series comparison?" |
| `landing` | Page structures + CTA strategies | "landing page layout for B2B SaaS" |
| `ux` | 98 UX best-practices + anti-patterns | "form UX best practices" |
| `product` | 161 product types (SaaS, e-commerce…) | "UI recommendations for marketplace" |

## Stack-specific output

Add `--stack` to get framework-specific code hints:

```bash
python3 $SKILL/scripts/search.py "dashboard" --domain style --stack react
python3 $SKILL/scripts/search.py "color" --domain color --stack nextjs
```

Available stacks (16): `html-tailwind` (default) · `react` · `nextjs` · `astro` · `vue` · `nuxtjs` · `nuxt-ui` · `svelte` · `angular` · `laravel` · `threejs` · `swiftui` · `react-native` · `flutter` · `shadcn` · `jetpack-compose`

## Generate a full design system

```bash
# Generates a complete design system for a described project
python3 $SKILL/scripts/design_system.py "fintech mobile app, dark mode, professional" --stack react
```

Output includes: chosen style + rationale, full color palette with hex codes, font pairing + Google Fonts import, spacing scale, component patterns, and an implementation checklist.

## Common usage patterns

```bash
SKILL=skills/ui-ux-pro-max

# "What UI style suits a healthcare SaaS dashboard?"
python3 $SKILL/scripts/search.py "healthcare saas dashboard" --domain style -n 3

# "Pick a color palette for a fintech app"
python3 $SKILL/scripts/search.py "fintech trust professional" --domain color -n 3

# "What fonts work for a luxury e-commerce brand?"
python3 $SKILL/scripts/search.py "luxury ecommerce elegant" --domain typography -n 2

# "What chart type is best for comparing monthly revenue across regions?"
python3 $SKILL/scripts/search.py "monthly revenue comparison regions" --domain chart -n 2

# "UX best practices for multi-step forms"
python3 $SKILL/scripts/search.py "multi-step form wizard" --domain ux -n 3

# "How should I structure a SaaS landing page?"
python3 $SKILL/scripts/search.py "saas landing page conversion" --domain landing -n 2

# Full design system in one shot (React + Tailwind)
python3 $SKILL/scripts/design_system.py "B2B project management tool, clean minimal, light mode" --stack nextjs
```

## Reading the output

Each result includes:
- **AI Prompt Keywords** — paste directly into an image-gen or design-gen prompt
- **CSS/Technical Keywords** — concrete CSS values to implement the look
- **Implementation Checklist** — step-by-step build checklist
- **Design System Variables** — CSS custom property names and values
- **Best For** — product types where this style works well
- **Accessibility** — WCAG level achieved

## Workflow tip

When a user asks for a UI recommendation, always:
1. Run `style` search to pick a visual language
2. Run `color` search matched to the product type
3. Run `typography` search for the brand feel
4. Synthesise into a concrete recommendation with the AI Prompt Keywords and CSS variables

This gives the user something they can immediately hand to a designer or paste into a component generator.
