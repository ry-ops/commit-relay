#!/usr/bin/env python3
"""
Generate a Corporate Memphis style project image for commit-relay
"""
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import Circle, Rectangle, FancyBboxPatch, Wedge, Polygon
import numpy as np

# Corporate Memphis color palette
COLORS = {
    'bg': '#FFFFFF',
    'purple': '#6C5CE7',
    'orange': '#FF6B6B',
    'teal': '#00D2D3',
    'yellow': '#FFD93D',
    'pink': '#FF6FB5',
    'blue': '#4834DF',
    'coral': '#FF7675',
    'mint': '#55EFC4',
}

# Create figure
fig, ax = plt.subplots(1, 1, figsize=(16, 9), facecolor=COLORS['bg'])
ax.set_xlim(0, 16)
ax.set_ylim(0, 9)
ax.axis('off')

# Title
ax.text(8, 8.2, 'commit-relay', fontsize=72, weight='bold',
        ha='center', va='top', color=COLORS['purple'], family='sans-serif')
ax.text(8, 7.6, 'AI-Powered Development Orchestration', fontsize=24,
        ha='center', va='top', color=COLORS['blue'], family='sans-serif', style='italic')

# Central coordinator figure (simplified person at computer)
# Head
head = Circle((8, 5.5), 0.4, color=COLORS['orange'], zorder=10)
ax.add_patch(head)

# Body
body = Rectangle((7.6, 4.2), 0.8, 1.3, color=COLORS['purple'], zorder=9)
ax.add_patch(body)

# Arms typing
left_arm = Polygon([(7.6, 5.2), (6.8, 5.0), (6.5, 4.7), (6.9, 4.9), (7.6, 4.8)],
                   color=COLORS['purple'], zorder=8)
right_arm = Polygon([(8.4, 5.2), (9.2, 5.0), (9.5, 4.7), (9.1, 4.9), (8.4, 4.8)],
                    color=COLORS['purple'], zorder=8)
ax.add_patch(left_arm)
ax.add_patch(right_arm)

# Laptop
laptop_base = Rectangle((6.8, 4.2), 2.4, 0.15, color=COLORS['blue'], zorder=7)
laptop_screen = Rectangle((7.2, 4.35), 1.6, 1.2, color=COLORS['teal'], zorder=6)
ax.add_patch(laptop_base)
ax.add_patch(laptop_screen)

# Code lines on laptop screen
for i, y_pos in enumerate([5.3, 5.1, 4.9, 4.7]):
    width = 1.2 - (i * 0.15)
    line = Rectangle((7.3, y_pos), width, 0.08, color='white', alpha=0.7, zorder=7)
    ax.add_patch(line)

# Worker nodes around the coordinator
worker_positions = [
    (3, 5.5, 'development-master', COLORS['coral']),
    (3, 3.5, 'security-master', COLORS['pink']),
    (13, 5.5, 'inventory-master', COLORS['mint']),
    (13, 3.5, 'cicd-master', COLORS['yellow']),
]

for x, y, label, color in worker_positions:
    # Worker icon (simplified person)
    worker_head = Circle((x, y + 0.5), 0.25, color=color, zorder=5)
    ax.add_patch(worker_head)

    worker_body = Rectangle((x - 0.2, y - 0.3), 0.4, 0.8, color=color, alpha=0.8, zorder=4)
    ax.add_patch(worker_body)

    # Label
    ax.text(x, y - 0.7, label, fontsize=11, ha='center',
            color=COLORS['blue'], weight='bold', family='sans-serif')

    # Connection line to center
    connection = plt.plot([x, 8], [y, 5.2], color=color, linewidth=3,
                         alpha=0.4, zorder=1, linestyle='--')[0]

# Task queue visualization (floating documents)
task_positions = [(2.5, 7.5), (4, 7.2), (12, 7.5), (13.5, 7.2)]
for i, (x, y) in enumerate(task_positions):
    # Document shape
    doc = FancyBboxPatch((x - 0.25, y - 0.35), 0.5, 0.7,
                         boxstyle="round,pad=0.05",
                         edgecolor=COLORS['purple'],
                         facecolor='white',
                         linewidth=2,
                         zorder=3)
    ax.add_patch(doc)

    # Lines on document
    for line_y in [y + 0.15, y, y - 0.15]:
        ax.plot([x - 0.15, x + 0.15], [line_y, line_y],
               color=COLORS['purple'], linewidth=1.5, alpha=0.6, zorder=4)

# Decorative geometric shapes
# Bottom left
circle1 = Circle((1.5, 1.5), 0.6, color=COLORS['yellow'], alpha=0.6, zorder=0)
ax.add_patch(circle1)

# Bottom right
triangle = Polygon([(14.5, 1), (15.5, 1), (15, 2.2)],
                   color=COLORS['pink'], alpha=0.6, zorder=0)
ax.add_patch(triangle)

# Top left decoration
semicircle = Wedge((1, 8), 0.8, 0, 180, color=COLORS['teal'], alpha=0.5, zorder=0)
ax.add_patch(semicircle)

# Top right decoration
rect_decor = Rectangle((14.5, 7.5), 1, 1, color=COLORS['coral'],
                       alpha=0.5, zorder=0, angle=25)
ax.add_patch(rect_decor)

# Add floating abstract shapes
dots = [(5.5, 2.5), (10.5, 2.5), (2, 6), (14, 6)]
dot_colors = [COLORS['mint'], COLORS['orange'], COLORS['yellow'], COLORS['purple']]
for (x, y), color in zip(dots, dot_colors):
    dot = Circle((x, y), 0.15, color=color, alpha=0.7, zorder=2)
    ax.add_patch(dot)

# Bottom tagline
ax.text(8, 1.2, 'Autonomous • Coordinated • Intelligent',
        fontsize=18, ha='center', color=COLORS['purple'],
        weight='bold', family='sans-serif', alpha=0.8)

# GitHub-style badges
badge_y = 0.5
badges = ['AI-Powered', 'Multi-Agent', 'Real-Time']
badge_colors = [COLORS['purple'], COLORS['teal'], COLORS['coral']]
start_x = 8 - (len(badges) * 1.2) / 2

for i, (badge_text, badge_color) in enumerate(zip(badges, badge_colors)):
    badge_x = start_x + i * 1.8
    badge_rect = FancyBboxPatch((badge_x, badge_y - 0.15), 1.4, 0.3,
                                boxstyle="round,pad=0.05",
                                facecolor=badge_color,
                                edgecolor='none',
                                zorder=5)
    ax.add_patch(badge_rect)
    ax.text(badge_x + 0.7, badge_y, badge_text,
           fontsize=10, ha='center', va='center',
           color='white', weight='bold', family='sans-serif', zorder=6)

plt.tight_layout()

# Save as PDF
output_file = '/Users/ryandahlberg/commit-relay/commit-relay-project-image.pdf'
plt.savefig(output_file, format='pdf', dpi=300, bbox_inches='tight',
            facecolor=COLORS['bg'], edgecolor='none')
print(f"✓ Created Corporate Memphis style image: {output_file}")

plt.close()
