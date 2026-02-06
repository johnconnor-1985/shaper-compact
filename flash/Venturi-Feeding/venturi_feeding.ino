// =====================================================
// Venturi Valve Controller
// Automatic cycle controller with sensor debounce
// =====================================================

// ---------------- Pin configuration ----------------

constexpr uint8_t PIN_VENTURI_RELAY = 2;
constexpr uint8_t PIN_STATUS_LED    = 3;
constexpr uint8_t PIN_BUZZER        = 12;
constexpr uint8_t PIN_SENSOR        = 4;
constexpr uint8_t PIN_TRIGGER       = 9;

// If true, sensor logic is inverted (active-low sensor)
const bool SENSOR_INVERTED = false;

// ---------------- System parameters ----------------

// Number of Venturi activation cycles before pause
const int MAX_VENTURI_CYCLES = 3;

// Number of silent pauses before alarm
const int MAX_PAUSE_BLOCKS = 3;

// Timing (milliseconds)
const int VENTURI_ACTIVE_TIME_MS  = 1000;
const int SILENT_PAUSE_MS         = 5000;
const int ALARM_DURATION_MS       = 3000;
const int ALARM_INTERVAL_MS       = 17000;
const int BOOT_DELAY_MS           = 10000;

// Debounce configuration
unsigned long venturiDebounceMs = 1000;
unsigned long sensorDebounceMs  = 1000;
unsigned int debounceSteps      = 10;

// ---------------- Runtime state ----------------

int venturiCycleCounter = 0;
int pauseBlockCounter   = 0;

bool lastTriggerState = LOW;
bool lastSensorState  = LOW;

// =====================================================
// Debounce helpers
// =====================================================

// Debounce trigger input (manual activation signal)
bool readStableTrigger()
{
  bool currentState = digitalRead(PIN_TRIGGER);

  if (currentState != lastTriggerState) {
    for (unsigned int i = 0; i < debounceSteps; i++) {
      delay(venturiDebounceMs / debounceSteps);

      if (currentState != digitalRead(PIN_TRIGGER))
        return lastTriggerState;
    }

    lastTriggerState = currentState;
  }

  return lastTriggerState;
}

// Debounce sensor input
bool readStableSensor()
{
  bool rawReading = digitalRead(PIN_SENSOR);
  bool currentState = SENSOR_INVERTED ? !rawReading : rawReading;

  if (currentState != lastSensorState) {
    for (unsigned int i = 0; i < debounceSteps; i++) {
      delay(sensorDebounceMs / debounceSteps);

      bool sample = SENSOR_INVERTED
                    ? !digitalRead(PIN_SENSOR)
                    : digitalRead(PIN_SENSOR);

      if (currentState != sample)
        return lastSensorState;
    }

    lastSensorState = currentState;
  }

  return lastSensorState;
}

// =====================================================
// Arduino setup
// =====================================================

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

  // Allow hardware stabilization after power-up
  delay(BOOT_DELAY_MS);
}

// =====================================================
// Main control loop
// =====================================================

void loop()
{
  bool triggerActive = readStableTrigger();
  bool sensorActive  = readStableSensor();

  // Safety shutdown condition
  if (!triggerActive || sensorActive) {
    digitalWrite(PIN_VENTURI_RELAY, LOW);
    digitalWrite(PIN_STATUS_LED, LOW);

    venturiCycleCounter = 0;
    pauseBlockCounter = 0;

    return;
  }

  // Venturi cycle management
  if (venturiCycleCounter >= MAX_VENTURI_CYCLES) {

    venturiCycleCounter = 0;

    digitalWrite(PIN_VENTURI_RELAY, LOW);
    digitalWrite(PIN_STATUS_LED, LOW);

    // Alarm logic
    if (pauseBlockCounter >= MAX_PAUSE_BLOCKS) {

      pauseBlockCounter = 0;

      digitalWrite(PIN_BUZZER, HIGH);
      delay(ALARM_DURATION_MS);
      digitalWrite(PIN_BUZZER, LOW);

      delay(ALARM_INTERVAL_MS);

    } else {

      delay(SILENT_PAUSE_MS);
      pauseBlockCounter++;

    }

  } else {

    // Activate Venturi valve
    digitalWrite(PIN_VENTURI_RELAY, HIGH);
    digitalWrite(PIN_STATUS_LED, HIGH);

    delay(VENTURI_ACTIVE_TIME_MS);
    venturiCycleCounter++;

  }
}
