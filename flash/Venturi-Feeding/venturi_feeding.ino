#include <Arduino.h>

// ============================================================
// Venturi Valve Controller (non-blocking)
// ------------------------------------------------------------
// Controls a Venturi valve (relay) using timed cycles and a
// safety capacitive sensor with debounce filtering.
//
// Non-blocking design:
// • Timing uses millis() (no delay())
// • Inputs use non-blocking debounce sampling
//
// Added I/O features:
// • PIN_FILTERED_SENSOR_STATE  -> outputs debounced sensor state
// • PIN_FILTERED_SENSOR_LED    -> mirrors debounced sensor state
// • PIN_LOADING_LED            -> ON when relay is ON
// • PIN_WARNING_LED            -> turns ON at first alarm and stays ON
//                                 until sensor becomes FULL again
// • PIN_PAUSE_COMMAND          -> after N warnings, pulse HIGH for 1s
// • PIN_FORCED_LOADING         -> debounced manual "force load" input
//                                 (overrides everything, resets cycles)
// ============================================================


// ================= PIN CONFIGURATION =================
// Change these only if you rewire hardware

constexpr uint8_t PIN_VENTURI_RELAY          = 2;   // Output: Relay controlling Venturi valve
constexpr uint8_t PIN_BUZZER                 = 3;   // Output: Alarm buzzer

constexpr uint8_t PIN_FILTERED_SENSOR_STATE  = 8;   // Output: Debounced sensor state (logic-level)
constexpr uint8_t PIN_PAUSE_COMMAND          = 9;   // Output: Pulse HIGH for 1s after N warnings
constexpr uint8_t PIN_LOADING_LED            = 10;  // Output: ON while relay is ON
constexpr uint8_t PIN_FILTERED_SENSOR_LED    = 11;  // Output: Mirrors debounced sensor state
constexpr uint8_t PIN_WARNING_LED            = 12;  // Output: ON after first alarm, until sensor FULL again

constexpr uint8_t PIN_SENSOR                 = 4;   // Input: Capacitive sensor input
constexpr uint8_t PIN_TRIGGER                = 5;   // Input: Turn system on
constexpr uint8_t PIN_FORCED_LOADING         = 6;   // Input: Force loading while pressed


// ================= LOGIC POLARITY =================
// Set true if sensor logic is inverted (active-low sensor)
const bool SENSOR_INVERTED = false;

// Optional (if your trigger / forced button are active-low, set these)
const bool TRIGGER_INVERTED        = false;
const bool FORCED_LOADING_INVERTED = false;


// ================= VENTURI BEHAVIOR =================

const int MAX_VENTURI_CYCLES = 3;   // How many activations before a pause
const int MAX_PAUSE_BLOCKS   = 2;   // Silent pauses before alarm

// After how many "warnings" (alarm starts) we pulse PIN_PAUSE_COMMAND
const int WARNINGS_BEFORE_PAUSE_PULSE = 5;

// All timings in milliseconds
const unsigned long VENTURI_ACTIVE_TIME_MS = 5000;   // Valve ON duration
const unsigned long SILENT_PAUSE_MS        = 20000;  // Pause between cycles
const unsigned long ALARM_DURATION_MS      = 2500;   // Buzzer ON time
const unsigned long ALARM_INTERVAL_MS      = 30000;  // Pause after alarm
const unsigned long BOOT_DELAY_MS          = 10000;  // Power-up stabilization

// Pause command pulse duration
const unsigned long PAUSE_PULSE_MS         = 1000;   // PIN_PAUSE_COMMAND HIGH for 1s


// ================= DEBOUNCE SETTINGS =================
//
// Debounce filters noisy inputs using:
// total time + number of samples
//
// Example:
// 1000 ms total / 10 samples = sample every 100 ms
//
// The new state is accepted ONLY if all samples match.
//

unsigned long triggerDebounceMs = 1000;
unsigned long sensorDebounceMs  = 1000;

// Forced loading should feel like a "button": typically shorter debounce
unsigned long forcedDebounceMs  = 120;

unsigned int  debounceSamples   = 10;
unsigned int  forcedSamples     = 5;


// ============================================================
// STATE MACHINE
// ============================================================

enum SystemState {
  STATE_IDLE,        // Waiting for valid trigger
  STATE_VENTURI_ON,  // Venturi active
  STATE_SILENT_WAIT, // Silent pause
  STATE_ALARM_ON,    // Alarm buzzer active
  STATE_ALARM_WAIT   // Pause after alarm
};


// ============================================================
// DEBOUNCER STRUCTURE
// ============================================================

struct Debouncer {
  uint8_t pin;
  bool inverted;

  unsigned long totalDebounceMs;
  unsigned int samples;

  bool stableState;

  bool debouncing;
  bool candidateState;
  unsigned int okSamples;
  unsigned long nextSampleAt;
};


// ============================================================
// FUNCTION PROTOTYPES
// ============================================================

static void enterState(SystemState s, unsigned long now);
static bool readPin(uint8_t pin, bool inverted);
static void debouncerInit(Debouncer &d,
                          uint8_t pin,
                          bool inverted,
                          unsigned long totalDebounceMs,
                          unsigned int samples,
                          bool initialStable);
static bool debouncerUpdate(Debouncer &d, unsigned long now);

static void allOutputsOff();
static void resetCycleCounters(bool resetWarnings);
static void updatePausePulse(unsigned long now);
static void startPausePulse(unsigned long now);


// ============================================================
// GLOBAL STATE
// ============================================================

SystemState state = STATE_IDLE;
unsigned long stateStart = 0;

int venturiCycleCount = 0;
int pauseBlockCount   = 0;

// Counts how many times we ENTER STATE_ALARM_ON since last reset
int warningCount      = 0;

// Warning LED latch: ON after first alarm, OFF only when sensor FULL again
bool warningLatched   = false;

// Pause pulse runtime
bool pausePulseActive = false;
unsigned long pausePulseStart = 0;

Debouncer triggerDb;
Debouncer sensorDb;
Debouncer forcedDb;


// ============================================================
// STATE MANAGEMENT
// ============================================================

static void enterState(SystemState s, unsigned long now) {
  state = s;
  stateStart = now;
}


// ============================================================
// RAW PIN READ WITH OPTIONAL INVERSION
// ============================================================

static bool readPin(uint8_t pin, bool inverted) {
  bool v = digitalRead(pin);
  return inverted ? !v : v;
}


// ============================================================
// DEBOUNCE INITIALIZATION
// ============================================================

static void debouncerInit(Debouncer &d,
                          uint8_t pin,
                          bool inverted,
                          unsigned long totalDebounceMs,
                          unsigned int samples,
                          bool initialStable)
{
  d.pin = pin;
  d.inverted = inverted;
  d.totalDebounceMs = totalDebounceMs;
  d.samples = (samples == 0 ? 1 : samples);

  d.stableState = initialStable;

  d.debouncing = false;
  d.candidateState = initialStable;
  d.okSamples = 0;
  d.nextSampleAt = 0;
}


// ============================================================
// NON-BLOCKING DEBOUNCE UPDATE
// ============================================================

static bool debouncerUpdate(Debouncer &d, unsigned long now)
{
  const bool currentReading = readPin(d.pin, d.inverted);

  if (!d.debouncing && currentReading != d.stableState) {
    d.debouncing = true;
    d.candidateState = currentReading;
    d.okSamples = 0;

    const unsigned long interval = d.totalDebounceMs / d.samples;
    d.nextSampleAt = now + interval;
    return d.stableState;
  }

  if (d.debouncing) {
    const unsigned long interval = d.totalDebounceMs / d.samples;

    while (d.debouncing && (long)(now - d.nextSampleAt) >= 0) {
      const bool sampleReading = readPin(d.pin, d.inverted);

      if (sampleReading != d.candidateState) {
        d.debouncing = false;
        d.okSamples = 0;
        return d.stableState;
      }

      d.okSamples++;

      if (d.okSamples >= d.samples) {
        d.stableState = d.candidateState;
        d.debouncing = false;
        d.okSamples = 0;
        return d.stableState;
      }

      d.nextSampleAt += interval;
    }
  }

  return d.stableState;
}


// ============================================================
// HELPERS
// ============================================================

static void allOutputsOff() {
  digitalWrite(PIN_VENTURI_RELAY, LOW);
  digitalWrite(PIN_LOADING_LED, LOW);

  digitalWrite(PIN_BUZZER, LOW);

  // Pause pulse output:
  digitalWrite(PIN_PAUSE_COMMAND, LOW);
  pausePulseActive = false;
}

static void resetCycleCounters(bool resetWarnings) {
  venturiCycleCount = 0;
  pauseBlockCount   = 0;

  if (resetWarnings) {
    warningCount   = 0;
    warningLatched = false;
    digitalWrite(PIN_WARNING_LED, LOW);

    // also cancel any in-flight pause pulse
    digitalWrite(PIN_PAUSE_COMMAND, LOW);
    pausePulseActive = false;
  }
}

static void startPausePulse(unsigned long now) {
  // Pulse HIGH for PAUSE_PULSE_MS (non-blocking)
  pausePulseActive = true;
  pausePulseStart  = now;
  digitalWrite(PIN_PAUSE_COMMAND, HIGH);
}

static void updatePausePulse(unsigned long now) {
  if (pausePulseActive) {
    if (now - pausePulseStart >= PAUSE_PULSE_MS) {
      pausePulseActive = false;
      digitalWrite(PIN_PAUSE_COMMAND, LOW);
    }
  } else {
    // ensure LOW when not pulsing
    digitalWrite(PIN_PAUSE_COMMAND, LOW);
  }
}


// ============================================================
// SETUP
// ============================================================

void setup()
{
  pinMode(PIN_VENTURI_RELAY, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);

  pinMode(PIN_FILTERED_SENSOR_STATE, OUTPUT);
  pinMode(PIN_PAUSE_COMMAND, OUTPUT);
  pinMode(PIN_LOADING_LED, OUTPUT);
  pinMode(PIN_FILTERED_SENSOR_LED, OUTPUT);
  pinMode(PIN_WARNING_LED, OUTPUT);

  pinMode(PIN_SENSOR, INPUT);
  pinMode(PIN_TRIGGER, INPUT);
  pinMode(PIN_FORCED_LOADING, INPUT);

  // Default safe outputs
  digitalWrite(PIN_VENTURI_RELAY, LOW);
  digitalWrite(PIN_BUZZER, LOW);

  digitalWrite(PIN_FILTERED_SENSOR_STATE, LOW);
  digitalWrite(PIN_PAUSE_COMMAND, LOW);
  digitalWrite(PIN_LOADING_LED, LOW);
  digitalWrite(PIN_FILTERED_SENSOR_LED, LOW);
  digitalWrite(PIN_WARNING_LED, LOW);

  delay(BOOT_DELAY_MS);

  // Initialize debouncers using current readings
  debouncerInit(triggerDb, PIN_TRIGGER, TRIGGER_INVERTED,
                triggerDebounceMs, debounceSamples,
                readPin(PIN_TRIGGER, TRIGGER_INVERTED));

  debouncerInit(sensorDb, PIN_SENSOR, SENSOR_INVERTED,
                sensorDebounceMs, debounceSamples,
                readPin(PIN_SENSOR, SENSOR_INVERTED));

  debouncerInit(forcedDb, PIN_FORCED_LOADING, FORCED_LOADING_INVERTED,
                forcedDebounceMs, forcedSamples,
                readPin(PIN_FORCED_LOADING, FORCED_LOADING_INVERTED));

  enterState(STATE_IDLE, millis());
}


// ============================================================
// MAIN LOOP
// ============================================================

void loop()
{
  const unsigned long now = millis();

  // Always update pause pulse timing (non-blocking)
  updatePausePulse(now);

  // Update debounced inputs
  const bool triggerActive      = debouncerUpdate(triggerDb, now);
  const bool sensorActive       = debouncerUpdate(sensorDb,  now);   // "true" = sensor says FULL (per original logic)
  const bool forcedLoadingPress = debouncerUpdate(forcedDb,  now);

  // ----------------------------
  // Output filtered sensor state
  // ----------------------------
  // If you prefer the opposite semantic (e.g. "empty"), invert here.
  digitalWrite(PIN_FILTERED_SENSOR_STATE, sensorActive ? HIGH : LOW);
  digitalWrite(PIN_FILTERED_SENSOR_LED,   sensorActive ? HIGH : LOW);

  // ============================================================
  // FORCED LOADING OVERRIDE (manual)
  // ------------------------------------------------------------
  // Requirement:
  // • overrides everything (relay ON while pressed)
  // • resets cycles and warnings
  // • must turn OFF buzzer and warning LED
  // • keeps filtered sensor LED/state functionality
  // ============================================================
  if (forcedLoadingPress) {
    // Reset everything so when released we restart clean
    resetCycleCounters(true);

    // Hard override outputs
    digitalWrite(PIN_VENTURI_RELAY, HIGH);
    digitalWrite(PIN_LOADING_LED, HIGH);

    digitalWrite(PIN_BUZZER, LOW);
    digitalWrite(PIN_WARNING_LED, LOW);

    // Keep system state parked
    enterState(STATE_IDLE, now);
    return;
  }

  // ----------------------------
  // Warning LED latch management
  // ----------------------------
  // "PIN_WARNING_LED accende alla prima attivazione buzzer e rimane acceso
  // fino a che il sensore torna pieno"
  //
  // So: turn OFF only when sensor is FULL again.
  if (sensorActive) {
    warningLatched = false;
  }
  digitalWrite(PIN_WARNING_LED, warningLatched ? HIGH : LOW);

  // ============================================================
  // SAFETY OVERRIDE (normal mode)
  // ------------------------------------------------------------
  // If trigger OFF OR sensor FULL -> immediate shutdown + reset cycles
  // ============================================================
  if (!triggerActive || sensorActive) {
    allOutputsOff();

    // When system goes safe / idle, we reset cycles + warnings.
    // If you want to NOT clear warnings on trigger-off, split this logic.
    resetCycleCounters(true);

    enterState(STATE_IDLE, now);
    return;
  }

  // ============================================================
  // STATE MACHINE (normal mode: trigger ON + sensor NOT FULL)
  // ============================================================

  switch (state) {

    case STATE_IDLE:
      // Start loading sequence immediately when conditions are met
      enterState(STATE_VENTURI_ON, now);
      break;

    case STATE_VENTURI_ON:
      digitalWrite(PIN_VENTURI_RELAY, HIGH);
      digitalWrite(PIN_LOADING_LED, HIGH);

      if (now - stateStart >= VENTURI_ACTIVE_TIME_MS) {
        digitalWrite(PIN_VENTURI_RELAY, LOW);
        digitalWrite(PIN_LOADING_LED, LOW);

        venturiCycleCount++;

        if (venturiCycleCount >= MAX_VENTURI_CYCLES) {
          venturiCycleCount = 0;

          if (pauseBlockCount >= MAX_PAUSE_BLOCKS) {
            pauseBlockCount = 0;
            enterState(STATE_ALARM_ON, now);
          } else {
            pauseBlockCount++;
            enterState(STATE_SILENT_WAIT, now);
          }
        } else {
          // Repeat immediately another ON cycle
          enterState(STATE_VENTURI_ON, now);
        }
      }
      break;

    case STATE_SILENT_WAIT:
      // Silent pause between blocks
      if (now - stateStart >= SILENT_PAUSE_MS) {
        enterState(STATE_VENTURI_ON, now);
      }
      break;

    case STATE_ALARM_ON:
      // Alarm ON
      digitalWrite(PIN_BUZZER, HIGH);

      // Warning LED latches ON when buzzer starts (first time)
      if (!warningLatched) {
        warningLatched = true;
        digitalWrite(PIN_WARNING_LED, HIGH);
      }

      // Count warnings once per entry into this state
      // Guard window (counts only once per entry)
      if (now - stateStart < 20) {
        warningCount++;

        // After N warnings -> pulse pause command (like a button for external system)
        if (warningCount >= WARNINGS_BEFORE_PAUSE_PULSE) {
          warningCount = 0;     // reset after pulse (tweak if you want "every 5 warnings" continuously)
          startPausePulse(now);
        }
      }

      if (now - stateStart >= ALARM_DURATION_MS) {
        digitalWrite(PIN_BUZZER, LOW);
        enterState(STATE_ALARM_WAIT, now);
      }
      break;

    case STATE_ALARM_WAIT:
      // Wait after alarm
      if (now - stateStart >= ALARM_INTERVAL_MS) {
        enterState(STATE_VENTURI_ON, now);
      }
      break;
  }
}
