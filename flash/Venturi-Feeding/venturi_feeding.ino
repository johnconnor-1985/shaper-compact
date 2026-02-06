#include <Arduino.h>

// ============================================================
// Venturi Valve Controller
// ------------------------------------------------------------
// Controls a Venturi valve using timed cycles and a safety sensor.
// The firmware is fully non-blocking:
//
// • Venturi timing uses millis() instead of delay()
// • Input signals use non-blocking debounce
//
// This keeps the system responsive at all times.
// ============================================================



// ================= PIN CONFIGURATION =================
//
// Change these only if you rewire hardware
//

constexpr uint8_t PIN_VENTURI_RELAY = 2;   // Relay controlling Venturi valve
constexpr uint8_t PIN_STATUS_LED    = 3;   // Status LED
constexpr uint8_t PIN_BUZZER        = 12;  // Alarm buzzer
constexpr uint8_t PIN_SENSOR        = 4;   // Safety sensor input
constexpr uint8_t PIN_TRIGGER       = 9;   // External trigger input

// Set true if sensor logic is inverted (active-low sensor)
const bool SENSOR_INVERTED = false;



// ================= VENTURI BEHAVIOR =================
//
// These values define how the system cycles
//

const int MAX_VENTURI_CYCLES = 3;   // How many activations before a pause
const int MAX_PAUSE_BLOCKS   = 3;   // Silent pauses before alarm

// All timings in milliseconds
const unsigned long VENTURI_ACTIVE_TIME_MS = 1000;  // Valve ON duration
const unsigned long SILENT_PAUSE_MS        = 5000;  // Pause between cycles
const unsigned long ALARM_DURATION_MS      = 3000;  // Buzzer ON time
const unsigned long ALARM_INTERVAL_MS      = 17000; // Pause after alarm
const unsigned long BOOT_DELAY_MS          = 10000; // Power-up stabilization



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
unsigned int  debounceSamples   = 10;



// ============================================================
// STATE MACHINE
// ------------------------------------------------------------
// The controller always exists in exactly one state.
// Each state has:
//
// • behavior
// • start time
// • transition condition
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
// ------------------------------------------------------------
// Stores the runtime state of the debounce filter
//
// stableState  → last accepted clean value
// debouncing   → true while sampling
// candidate    → possible new value under test
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
// (Explicit prototypes prevent Arduino IDE auto-prototype bugs)
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



// ============================================================
// GLOBAL STATE
// ============================================================

SystemState state = STATE_IDLE;
unsigned long stateStart = 0;

int venturiCycleCount = 0;
int pauseBlockCount   = 0;

Debouncer triggerDb;
Debouncer sensorDb;



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
// Called once at boot to configure each input
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
// ------------------------------------------------------------
// Called every loop.
// Returns the current clean (stable) input state.
//
// Logic:
// • If reading changes → start sampling window
// • If all samples match → accept new state
// • If any sample fails → reject change
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
// SETUP
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

  // Initialize debouncers using current readings
  debouncerInit(triggerDb, PIN_TRIGGER, false,
                triggerDebounceMs, debounceSamples,
                readPin(PIN_TRIGGER, false));

  debouncerInit(sensorDb, PIN_SENSOR, SENSOR_INVERTED,
                sensorDebounceMs, debounceSamples,
                readPin(PIN_SENSOR, SENSOR_INVERTED));

  enterState(STATE_IDLE, millis());
}



// ============================================================
// MAIN LOOP
// ============================================================

void loop()
{
  const unsigned long now = millis();

  const bool triggerActive = debouncerUpdate(triggerDb, now);
  const bool sensorActive  = debouncerUpdate(sensorDb,  now);



  // ================= SAFETY OVERRIDE =================
  // If trigger OFF or sensor ON → immediate shutdown

  if (!triggerActive || sensorActive) {
    digitalWrite(PIN_VENTURI_RELAY, LOW);
    digitalWrite(PIN_STATUS_LED, LOW);
    digitalWrite(PIN_BUZZER, LOW);

    venturiCycleCount = 0;
    pauseBlockCount   = 0;

    enterState(STATE_IDLE, now);
    return;
  }



  // ================= STATE MACHINE =================

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
