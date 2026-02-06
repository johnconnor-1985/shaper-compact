// ============================================================
// Venturi Valve Controller
// - Non-blocking venturi timing (millis)
// - Non-blocking debounce
// ============================================================

// ---------------- Pin configuration ----------------
constexpr uint8_t PIN_VENTURI_RELAY = 2;
constexpr uint8_t PIN_STATUS_LED    = 3;
constexpr uint8_t PIN_BUZZER        = 12;
constexpr uint8_t PIN_SENSOR        = 4;
constexpr uint8_t PIN_TRIGGER       = 9;

// If true, sensor logic is inverted (active-low sensor)
const bool SENSOR_INVERTED = false;

// ---------------- Venturi behavior parameters ----------------
const int MAX_VENTURI_CYCLES = 3;
const int MAX_PAUSE_BLOCKS   = 3;

const unsigned long VENTURI_ACTIVE_TIME_MS = 1000;
const unsigned long SILENT_PAUSE_MS        = 5000;
const unsigned long ALARM_DURATION_MS      = 3000;
const unsigned long ALARM_INTERVAL_MS      = 17000;
const unsigned long BOOT_DELAY_MS          = 10000;

// ---------------- Debounce parameters ----------------
// Total debounce time and number of samples inside it.
// Example: 1000ms total, 10 samples -> sample every 100ms.
// The new state is accepted ONLY if all samples match the candidate state.
unsigned long triggerDebounceMs = 1000;
unsigned long sensorDebounceMs  = 1000;
unsigned int  debounceSamples   = 10;

struct Debouncer {
  uint8_t pin;
  bool inverted;

  // Configuration
  unsigned long totalDebounceMs;
  unsigned int samples;

  // Stable state (what the rest of the program sees)
  bool stableState;

  // Debounce-in-progress state
  bool debouncing;
  bool candidateState;
  unsigned int okSamples;
  unsigned long nextSampleAt;
};

static bool readPin(uint8_t pin, bool inverted) {
  bool v = digitalRead(pin);
  return inverted ? !v : v;
}

static void debouncerInit(Debouncer &d, uint8_t pin, bool inverted,
                          unsigned long totalDebounceMs, unsigned int samples,
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

// Call this frequently (every loop). It returns the current stable state.
// When a change is detected, it starts sampling over time.
// Until sampling completes successfully, it keeps returning the old stable state.
static bool debouncerUpdate(Debouncer &d, unsigned long now)
{
  const bool currentReading = readPin(d.pin, d.inverted);

  // If we are not currently debouncing and we see a change vs stableState:
  if (!d.debouncing && currentReading != d.stableState) {
    d.debouncing = true;
    d.candidateState = currentReading;
    d.okSamples = 0;

    // Sample interval matches original: totalDelay / samples
    const unsigned long interval = d.totalDebounceMs / d.samples;
    d.nextSampleAt = now + interval;  // first check happens after one interval
    return d.stableState;             // keep old stable state for now
  }

  // If we are debouncing, perform scheduled samples
  if (d.debouncing) {
    const unsigned long interval = d.totalDebounceMs / d.samples;

    // Take as many samples as needed if loop is slow
    while (d.debouncing && (long)(now - d.nextSampleAt) >= 0) {
      const bool sampleReading = readPin(d.pin, d.inverted);

      if (sampleReading != d.candidateState) {
        // Debounce failed -> cancel, keep previous stable state
        d.debouncing = false;
        d.okSamples = 0;
        return d.stableState;
      }

      // Sample matched candidate
      d.okSamples++;

      if (d.okSamples >= d.samples) {
        // Debounce success -> accept new stable state
        d.stableState = d.candidateState;
        d.debouncing = false;
        d.okSamples = 0;
        return d.stableState;
      }

      // Schedule next sample
      d.nextSampleAt += interval;
    }
  }

  // No change / still debouncing -> return current stable state
  return d.stableState;
}

// Two debounced inputs
Debouncer triggerDb;
Debouncer sensorDb;

// ============================================================
// State machine for venturi timing (millis-based)
// ============================================================

enum SystemState {
  STATE_IDLE,
  STATE_VENTURI_ON,
  STATE_SILENT_WAIT,
  STATE_ALARM_ON,
  STATE_ALARM_WAIT
};

SystemState state = STATE_IDLE;
unsigned long stateStart = 0;

int venturiCycleCount = 0;
int pauseBlockCount   = 0;

static void enterState(SystemState s, unsigned long now) {
  state = s;
  stateStart = now;
}

// ============================================================

void setup()
{
  pinMode(PIN_VENTURI_RELAY, OUTPUT);
  pinMode(PIN_STATUS_LED, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);

  pinMode(PIN_SENSOR, INPUT);
  pinMode(PIN_TRIGGER, INPUT);

  digitalWrite(PIN_VENTURI_RELAY, LOW);
  digitalWrite(PIN_STATUS_LED, LOW);
  digitalWrite(PIN_BUZZER, LOW);

  delay(BOOT_DELAY_MS);

  // Initialize debouncers.
  // Initial stable state is read once at boot (common embedded practice).
  debouncerInit(triggerDb, PIN_TRIGGER, false,          triggerDebounceMs, debounceSamples,
                readPin(PIN_TRIGGER, false));
  debouncerInit(sensorDb,  PIN_SENSOR,  SENSOR_INVERTED, sensorDebounceMs,  debounceSamples,
                readPin(PIN_SENSOR, SENSOR_INVERTED));

  enterState(STATE_IDLE, millis());
}

void loop()
{
  const unsigned long now = millis();

  // Update debounced inputs (non-blocking)
  const bool triggerActive = debouncerUpdate(triggerDb, now);
  const bool sensorActive  = debouncerUpdate(sensorDb,  now);

  // Safety override (same logic as your original):
  // If trigger is false OR sensor is true -> everything OFF + reset counters.
  if (!triggerActive || sensorActive) {
    digitalWrite(PIN_VENTURI_RELAY, LOW);
    digitalWrite(PIN_STATUS_LED, LOW);
    digitalWrite(PIN_BUZZER, LOW);

    venturiCycleCount = 0;
    pauseBlockCount   = 0;

    enterState(STATE_IDLE, now);
    return;
  }

  // State machine (non-blocking timing)
  switch (state) {

    case STATE_IDLE:
      enterState(STATE_VENTURI_ON, now);
      break;

    case STATE_VENTURI_ON:
      digitalWrite(PIN_VENTURI_RELAY, HIGH);
      digitalWrite(PIN_STATUS_LED, HIGH);

      if (now - stateStart >= VENTURI_ACTIVE_TIME_MS) {
        digitalWrite(PIN_VENTURI_RELAY, LOW);
        digitalWrite(PIN_STATUS_LED, LOW);

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
          // Next venturi activation
          enterState(STATE_VENTURI_ON, now);
        }
      }
      break;

    case STATE_SILENT_WAIT:
      if (now - stateStart >= SILENT_PAUSE_MS) {
        enterState(STATE_VENTURI_ON, now);
      }
      break;

    case STATE_ALARM_ON:
      digitalWrite(PIN_BUZZER, HIGH);

      if (now - stateStart >= ALARM_DURATION_MS) {
        digitalWrite(PIN_BUZZER, LOW);
        enterState(STATE_ALARM_WAIT, now);
      }
      break;

    case STATE_ALARM_WAIT:
      if (now - stateStart >= ALARM_INTERVAL_MS) {
        enterState(STATE_VENTURI_ON, now);
      }
      break;
  }
}
