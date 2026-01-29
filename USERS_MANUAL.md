# FlowRecovery User Manual

## Overview

FlowRecovery is an HRV (Heart Rate Variability) monitoring app designed to track recovery, readiness, and overall health. It works exclusively with the Polar H10 chest strap and integrates with Apple HealthKit for sleep, training, and vitals data.

---

## App Navigation

The app has 5 tabs at the bottom of the screen:

| Tab | Icon | Purpose |
|-----|------|---------|
| **Recovery** | Heart | Dashboard showing recovery status |
| **Record** | Waveform | Collect HRV data from your Polar H10 |
| **History** | List | Browse all past sessions |
| **Trends** | Chart | Long-term pattern analysis |
| **Settings** | Gear | Configuration and data management |

---

## Recovery Tab (Dashboard)

The main dashboard displays your recovery status at a glance.

### Recovery Score Card
- Large circular gauge showing overall recovery (0-100)
- Combines HRV, sleep quality, training load, and vitals
- Color coded:
  - **Green** (80+): Fully recovered
  - **Gold** (60-79): Moderately recovered
  - **Terracotta** (40-59): Reduced recovery
  - **Dusty Rose** (<40): Poor recovery

### HRV Card
- Shows your latest RMSSD value in milliseconds
- Labels based on value:
  - **Excellent**: 60+ ms
  - **Good**: 45-59 ms
  - **Fair**: 30-44 ms
  - **Low**: <30 ms
- Tap to open HRV Detail View

### Sleep Card
- Total sleep hours from HealthKit
- Sleep efficiency percentage
- Tap to open Sleep Detail View

### Training Load Card
*Only appears if Training Load Integration is enabled in Settings and you're not on a training break*
- **ACR Gauge**: Acute:Chronic Ratio showing training balance
- **ATL**: Acute Training Load (7-day fatigue)
- **CTL**: Chronic Training Load (42-day fitness)
- **TSB**: Training Stress Balance (form indicator)
- Tap to open Training Detail View

### Vitals Section
2x2 grid showing HealthKit data:
- **Respiratory Rate**: Breaths per minute with elevation status
- **SpO2**: Blood oxygen percentage
- **Temperature**: Wrist temperature deviation from baseline
- **Resting HR**: Resting heart rate
- Tap to open Vitals Detail View

### Insights Section
Auto-generated insights based on your current metrics and trends.

### Action Button
- **"View Recovery Report"**: Opens detailed report for today's morning session
- **"Take Morning Reading"**: Appears when no morning data exists, navigates to Record tab

---

## Detail Views

### HRV Detail View
- **Current HRV Hero Card**: Today's RMSSD with baseline comparison
- **Your Averages Card**: Average HRV, HR, and Readiness over last 30 sessions
- **View Full Report Button**: Opens today's detailed report
- **Nervous System Card**: HRV Score (1-10) and ANS balance (sympathetic vs parasympathetic)
- **30-Day Trend Chart**: Line chart with baseline reference line
- **Statistics Card**: 30-day average, range, coefficient of variation, baseline
- **Recent Readings**: Last 7 readings with tap to view report
- **Education Card**: Tips about HRV interpretation

### Sleep Detail View
- **Sleep Score Card**: Composite 0-100 score based on:
  - Duration (40 points)
  - Efficiency (30 points)
  - Deep sleep percentage (15 points)
  - REM sleep percentage (15 points)
- **Sleep Duration Card**: Hours slept vs your typical sleep goal
- **Sleep Timing Card**: Sleep start/end times, time in bed
- **Sleep Stages Card**: Visual bar showing deep/light/REM/awake breakdown with percentages
- **Key Metrics Grid**: Efficiency, awake time, sleep time, time in bed, sleep latency
- **Quality Check Card**: Checkmarks comparing each metric to targets
- **Sleep Insights Card**: Auto-generated tips based on your data

### Training Detail View
- **ACR Card**: Large ACR value with zone label and gauge bar
- **Training Metrics Card**: ATL, CTL, TSB display
- **ACR Training Zones**:
  - **Under** (<0.8): Undertraining - fitness declining
  - **Maintenance** (0.8-1.0): Maintaining fitness
  - **Optimal** (1.0-1.3): Building fitness
  - **Overreaching** (1.3-1.5): Monitor recovery closely
  - **Injury Risk** (>1.5): Reduce training immediately
- **Recent Workouts Card**: List of recent workouts with type, date, duration, TRIMP

### Vitals Detail View
- **Status Banner**: Overall status (Normal/Elevated/Warning)
- **Vitals Score Card**: Score circle with quick stats
- **Expandable Cards** for each vital:
  - Resting Heart Rate
  - Respiratory Rate (with baseline comparison)
  - Blood Oxygen (SpO2)
  - Wrist Temperature (deviation from baseline)
- **Explanation Card**: Tips about recovery vitals

---

## Record Tab

Collect HRV data from your Polar H10 chest strap.

### Connection Section

**When Disconnected:**
- **"Reconnect to Last Device"** button (if previously connected)
- **"Scan for Devices"** button
- Instruction: "Put on your Polar H10 strap and moisten the electrodes"

**When Scanning:**
- Shows progress spinner with "Scanning for Polar H10..."
- Lists discovered devices with signal strength (dBm)
- Tap a device name to connect
- **"Stop Scanning"** button

**When Connecting:**
- Shows progress spinner with "Connecting..."

**When Connected:**
- Device ID and battery level percentage
- Live heart rate display with pulsing animation
- **"Disconnect"** button
- Recording status indicator if active

### Tag Selection
- Horizontal scrollable row of system tags: Morning, Afternoon, Evening, Post-Workout, etc.
- Tap tags to select/deselect
- **"More"** button opens full tag picker sheet with all system and custom tags

### Morning Reading Section (Overnight Recording)

For overnight HRV monitoring during sleep:

**Starting a Recording:**
1. Connect your H10 before bed
2. Select any tags you want (Morning tag is auto-added for overnight recordings)
3. Tap **"Start Overnight Streaming"**
4. Keep the app open overnight (silent audio keeps it running in background)

**While Recording:**
- Shows moon icon with "Streaming overnight..."
- Displays elapsed time (HH:MM:SS format)
- Shows heartbeats collected count
- Shows current BPM
- Message: "Keep the app open - silent audio keeps it running in background"
- Instruction: "Tap 'Get Morning Reading' when you wake up"

**Getting Results:**
- When you wake up, tap **"Get Morning Reading"**
- App analyzes your data and finds the best 5-minute analysis window from the last 60 minutes of sleep

**Analysis Window:**
- The app automatically selects the optimal 5-minute window for HRV analysis
- Uses the window selection method set in Settings (default: Auto Select)

### Quick Reading Section (Spot Check)

For daytime 2-5 minute readings:

**Starting:**
- Choose duration: **2 min** (Basic) | **3 min** (Standard) | **5 min** (Full)
- Sit still and relax during recording

**During Recording:**
- Countdown timer showing remaining time
- Progress ring with live HR in center
- Real-time waveform visualization
- Breathing mandala for coherence (breathe with it for better results)
- Stats row: Beats collected, elapsed time, average RR interval
- **"Stop Early"** button available

**After Recording:**
- "Reading Complete" card shows RMSSD, HR, and Readiness/SDNN
- **"View Full Report"** button opens detailed results
- **"Done"** button saves and resets

### Data Quality Verification
After recording completes, shows:
- Quality badge (Good/Issues Found)
- Analysis window duration
- Quality score percentage
- Artifact percentage (<10% is good)
- Clean beats count (200+ is good)
- Any errors or warnings

### Results Preview

**For Overnight Recordings:**
- "Morning Analysis Ready" card
- Shows RMSSD, Readiness score, HR
- **"View Full Report"** button opens MorningResultsView
- Accept/Discard buttons to save or reject the session

**For Quick Readings:**
- "Reading Complete" card
- Shows RMSSD, HR, Readiness/SDNN
- **"View Full Report"** button
- **"Done"** button

### Data Recovery

**If H10 has stored data from a previous session:**
- "Data Found on H10" alert appears
- **"Recover Data"**: Downloads and analyzes the stored session
- **"Discard & Start Fresh"**: Clears H10 memory to start new recording

**If fetch fails:**
- "Data Fetch Failed" alert
- Data is still safe on H10
- **"Retry Fetch Data"** button
- **"Dismiss"** button

---

## History Tab

Browse all your past HRV sessions.

### Session Type Filter
Horizontal buttons at top:
- **All**: Show all session types
- **Overnight**: Sleep recordings (2+ hours)
- **Naps**: Shorter sleep recordings
- **Quick**: Streaming spot checks

### Tag Filter
Scrollable row below type filter:
- **"All"** button clears tag filters
- System tags with color coding
- Tap multiple tags to filter (shows sessions matching ANY selected tag)

### Search
- Search bar at top
- Search by date, tag name, or notes content

### Session List
Sessions grouped by time period:
- Today
- Yesterday
- This Week
- Last Week
- [Month Year] for older sessions

**Each Session Row Shows:**
- Session type icon (moon for overnight, clock for quick, etc.)
- Time (analysis window end time for overnight, or session start time)
- Session type badge ("Nap" or "Quick" if applicable)
- Date
- Tags (first 3 shown, "+N" if more)
- RMSSD value (large, right-aligned)
- Readiness score indicator:
  - Green checkmark: 7+
  - Yellow minus: 5-7
  - Orange exclamation: <5
- Chevron indicating tap for details

### Swipe Actions
- **Swipe Left (trailing)**: Red "Delete" button
- **Swipe Right (leading)**: Blue "Edit Tags" button

### Tap Session
Opens the full MorningResultsView in a sheet.

### Empty State
- Shows when no sessions exist or no sessions match filters
- **"Clear Filters"** button appears when filtering

---

## Trends Tab

Analyze patterns across multiple sessions.

### Tag Filter Bar
- **"Filter by Tags"** header
- **"Clear"** button (appears when filters active)
- Filter settings button (slider icon) opens full filter sheet
- Quick chips: "All" + first 4 system tags
- Shows "[excluded count] excluded" if any tags excluded
- Active filter summary: "X of Y sessions" when filtered

**Filter Sheet:**
- Include section: Select tags to show only sessions with those tags
- Exclude section: Select tags to hide sessions with those tags
- **"Clear All Filters"** button

### Period Selector
Horizontal buttons:
- 1 Week | 2 Weeks | 1 Month | 3 Months | All Time

### Overall Trend Card
- Direction icon:
  - Green up arrow: Improving
  - Blue left-right arrows: Stable
  - Orange down arrow: Declining
  - Gray question mark: Insufficient data
- Session count
- Date range

### Trend Chart
**Metric Selector Tabs:**
- RMSSD | SDNN | HR | LF/HF | DFA | Stress | Readiness

**Chart Shows:**
- Blue line with points: Individual readings
- Orange dashed line: 3-day rolling average

**Legend:**
- Blue dot = Value
- Orange dash = 3-day avg

### Statistics Grid
For each metric, shows a card with:
- Metric name
- Mean value with standard deviation (±)
- Trend arrow (up/stable/down)
- Session count
- Deviation from baseline percentage

**Metrics displayed:**
- RMSSD (ms)
- SDNN (ms)
- HR (bpm)
- LF/HF (if available)
- DFA α1 (if available)
- Stress Index (if available)
- Readiness (/10)

### Insights Section
- Lightbulb icon
- Auto-generated insights about your patterns
- "Keep recording to generate insights" if insufficient data

### No Data State
- Chart icon
- "Not Enough Data"
- "Record at least 2 sessions to see trends"

---

## Detailed Report View (MorningResultsView)

Comprehensive recovery report accessed from Dashboard or History.

### Header Section
- "Recovery Report" title
- Session date
- Quality badge (Excellent if artifact <5%, Good otherwise)
- Beat count
- Analysis window info (e.g., "Best 4.9 min window from overnight recording")

### Key Metrics Section
- **HRV Hero Card**: Large RMSSD display with:
  - Value in ms
  - Label (Excellent/Good/Fair/Reduced/Low)
  - Age-adjusted context (if age configured)
  - Tap for explanation popover
- **Heart Rate Stats Row**: Min HR, Avg HR, Max HR, SDNN

### Readiness Section
- "Recovery Readiness" header with info button
- Large gauge (0-10 scale)
- Color-coded score
- Interpretation text

### Training Load Section
*Only appears if training data available*
- ACR gauge with zone indicator
- ATL/CTL/TRIMP metrics
- Recent workouts list (if available)

### Analysis Summary Section
- AI-generated paragraph summarizing your recovery status

### Window Selection Method
*Only for overnight sessions with raw data*
- Picker to change analysis method: Lowest HR, Most Stable, Auto Select
- Re-analyze button

### Peak Capacity Section
- Highest sustained 5-minute HRV period
- Shows RMSSD value and time

### Overnight Charts Section
- HR trend during sleep
- Sleep stage overlay (if HealthKit data available)
- HR dip visualization
- Tap chart to reanalyze at specific time point

### Heart Rate Section
- "Heart Rate Over Time" chart
- Shows HR trend throughout recording
- Min-Max range indicator
- Legend and tap instructions

### Technical Details Section
*Collapsed by default - tap to expand*
- **Tachogram**: RR interval time series chart
- **Poincaré Plot**: SD1/SD2 scatter plot with ellipse
- **Frequency Domain** (if available): LF/HF power, LF/HF ratio
- **Additional Metrics**: pNN50, DFA α1, Stress Index

### Trends Section
- Comparison with recent sessions
- Baseline deviation

### Tags Section
- Current tags on session
- Tap to add/remove tags

### Notes Section
- Text field for session notes
- Auto-saves when changed

### Action Buttons
- **"View PDF Report"**: Generates shareable PDF
- **"Delete"** (if viewing from History): Permanently deletes session
- **"Reanalyze"**: Re-runs analysis with different window selection

---

## Settings Tab

### Profile Section
- **Birthday**: Set your date of birth (used for age-based HRV interpretation)
- **Age**: Auto-calculated from birthday
- **Fitness Level**: Not Set / Sedentary / Lightly Active / Moderately Active / Very Active / Extremely Active
- **Biological Sex**: Not Set / Male / Female / Other

### Sleep Section
- **Typical Sleep**: Your normal sleep duration (5-10 hours, 0.5 hour increments)
- Note: Shorter nights show discounted HRV to reflect incomplete recovery

### Units Section
- **Temperature**: Celsius (°C) or Fahrenheit (°F)

### Baselines Section (Read-only)
- **Personal Baseline**: Calculated from your morning readings
- **Population Baseline**: Estimated from your age and fitness level

### Fitness Integration Section
- **VO2max Override**: Manually enter your known VO2max (ml/kg/min)
- **Use HealthKit VO2max**: Toggle to pull VO2max from Apple Health
- **Training Load Integration**: Enable/disable training metrics on dashboard
- **Training Break**: Set start/end dates and reason for break (hides training metrics during sick days, vacation, surgery recovery)

### Recording Section
- **Default Duration**: Default quick reading length (1 / 2 / 3 / 5 minutes)
- **Show Advanced Metrics**: Toggle display of technical/scientific metrics

### Custom Tags Section
- List of your custom tags with color indicators
- Swipe left to delete custom tags
- **"Add Custom Tag"** button opens creation sheet:
  - Tag name text field
  - 12-color grid for tag color
  - Live preview
  - Save button

### About Section
- **Version**: Current app version number
- **Source Code**: Link to GitHub repository
- **Metric Explanations**: Expandable guide to all HRV metrics

### Data Section
- **Import RR Data**: Import data from other sources
- **Export Data**: Opens export options view
- **Recover RR from Strap**: Downloads missed data from H10 (only appears when H10 is connected)
- **Recover Lost Sessions**: Find sessions from backup that aren't in archive
- **Trash**: View deleted sessions with count badge

---

## Trash View

Manage deleted sessions.

### When Empty
- "Trash is Empty" message
- "Deleted sessions will appear here for recovery"

### With Deleted Sessions
- List showing each deleted session:
  - Date and time
  - Beat count
  - **Restore button** (green arrow): Recovers and re-analyzes the session
  - **Permanent delete button** (red X): Removes from trash
- Footer: "Deleted sessions are kept until permanently removed or until backups are purged (90 days)"
- **"Permanently Delete All"** button with confirmation dialog

---

## Lost Sessions View

Recover sessions that have raw backups but aren't in the main archive.

### Features
- List of lost sessions with date, beat count, duration estimate
- **"Recover All"** button to batch recover
- **Edit mode** with multi-select for batch deletion
- **Swipe to delete** individual sessions
- Confirmation dialog before deletion

---

## HRV Metrics Explained

### Time Domain Metrics
| Metric | Description | Good Values |
|--------|-------------|-------------|
| **RMSSD** | Root Mean Square of Successive Differences. Primary HRV metric indicating parasympathetic activity. Higher = better recovery. | 40-100+ ms (age-dependent) |
| **SDNN** | Standard Deviation of NN intervals. Overall variability measure. | 50-100+ ms |
| **pNN50** | Percentage of successive intervals differing >50ms. | >20% |
| **Mean HR** | Average heart rate during analysis window. | Varies by fitness |
| **Min/Max HR** | Lowest and highest heart rate during recording. | -- |

### Frequency Domain Metrics
| Metric | Description |
|--------|-------------|
| **LF Power** | Low Frequency power (0.04-0.15 Hz). Mix of sympathetic and parasympathetic activity. |
| **HF Power** | High Frequency power (0.15-0.4 Hz). Primarily parasympathetic (vagal) activity. |
| **LF/HF Ratio** | Balance between sympathetic and parasympathetic. Lower generally indicates better recovery. |

### Nonlinear Metrics
| Metric | Description |
|--------|-------------|
| **SD1** | Short-term HRV from Poincaré plot. Reflects beat-to-beat variability. |
| **SD2** | Long-term HRV from Poincaré plot. Reflects overall variability. |
| **DFA α1** | Detrended Fluctuation Analysis. Values 0.75-1.0 suggest healthy complexity. |

### Composite Metrics
| Metric | Description |
|--------|-------------|
| **Stress Index** | Baevsky's stress index. Lower values indicate less physiological stress. |
| **Readiness Score** | Composite 0-10 score combining HRV, HR, and recovery factors. |
| **Recovery Score** | Composite 0-100 score combining HRV, sleep, training, and vitals. |

---

## Tips for Best Results

### General
1. **Consistency**: Take readings at the same time each day
2. **Morning readings**: Best done immediately after waking, before getting up
3. **Stay still**: Minimize movement during recording
4. **Relax**: Breathe normally, don't stress about the measurement

### Polar H10 Setup
1. **Electrode contact**: Moisten the electrode pads before putting on the strap
2. **Strap fit**: Snug but comfortable, just below chest muscles
3. **Battery**: Keep H10 charged (app shows battery level when connected)
4. **Range**: Keep phone within Bluetooth range (a few meters)

### Overnight Recording
1. **Before bed**: Start recording after you're already in bed
2. **Phone placement**: Keep within Bluetooth range but doesn't need to be right next to you
3. **App open**: The app uses silent audio to stay active - don't close it
4. **Morning**: Tap "Get Morning Reading" soon after waking

### Building Your Baseline
- Record for 2+ weeks to establish your personal baseline
- Morning readings are most consistent for baseline calculation
- The app learns your normal patterns over time

---

## Troubleshooting

### H10 Connection Issues
- **Won't connect**: Moisten electrodes, check battery, move phone closer
- **Disconnects during recording**: Check strap fit, ensure electrodes are moist
- **No devices found**: Make sure H10 is being worn (skin contact activates it)

### Poor Signal Quality
- High artifact percentage indicates poor signal
- Solutions: Adjust strap position, add moisture, check strap condition

### Missing Overnight Data
- Ensure app stayed open overnight (check battery settings)
- If app was killed, use "Recover RR from Strap" option in Settings > Data
- Check "Recover Lost Sessions" for backup recovery

### Sessions Missing from History
- Check "Recover Lost Sessions" in Settings > Data
- Check "Trash" for accidentally deleted sessions
- Sessions in trash are kept for 90 days

### HealthKit Data Not Showing
- Grant HealthKit permissions when prompted
- Check Settings > Privacy > Health > FlowRecovery
- Sleep data requires Apple Watch or compatible sleep tracker

---

## Privacy & Data

- All HRV data is stored locally on your device
- Raw RR interval backups are stored in the App Group container (survives app reinstalls)
- HealthKit data access requires explicit permission
- Export options available for backup and data portability
- No data is sent to external servers
