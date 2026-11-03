//+------------------------------------------------------------------+
//|                                                PropFirmGuard.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Standard Library                                                 |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
//| Represents the general compliance condition of the account.      |
//+------------------------------------------------------------------+
enum ENUM_COMPLIANCE_STATUS
  {
   COMPLIANCE_SAFE = 0,          // Account is operating within configured limits
   COMPLIANCE_WARNING,           // Account is approaching a compliance limit
   COMPLIANCE_CRITICAL,          // Account is very close to a compliance limit
   COMPLIANCE_BREACHED           // A configured compliance limit has been breached
  };

//+------------------------------------------------------------------+
//| Profit target status                                             |
//+------------------------------------------------------------------+
//| Represents progress toward the configured account profit target. |
//+------------------------------------------------------------------+
enum ENUM_TARGET_STATUS
  {
   TARGET_IN_PROGRESS = 0,       // Target is still being pursued
   TARGET_NEARING,               // At least 90% of the target has been reached
   TARGET_REACHED                // Required target balance has been achieved
  };

//+------------------------------------------------------------------+
//| Overall guard status                                             |
//+------------------------------------------------------------------+
enum ENUM_GUARD_STATUS
  {
   GUARD_SAFE = 0,               // All monitored rules are within safe limits
   GUARD_TARGET_REACHED,         // Profit target has been achieved
   GUARD_WARNING,                // At least one rule is in warning state
   GUARD_CRITICAL,               // At least one rule is in critical state
   GUARD_BREACHED                // At least one drawdown rule has been breached
  };

//+------------------------------------------------------------------+
//| News monitoring status                                           |
//+------------------------------------------------------------------+
enum ENUM_NEWS_STATUS
  {
   NEWS_DISABLED = 0,             // Economic news monitoring is disabled
   NEWS_NO_EXPOSURE,              // No supported open positions require news monitoring
   NEWS_NO_EVENT,                 // No relevant event was found
   NEWS_SAFE,                     // Relevant event exists but restriction is inactive
   NEWS_RESTRICTED,               // Current time is inside the restricted news window
   NEWS_UNAVAILABLE               // Calendar data could not be retrieved
  };

//+------------------------------------------------------------------+
//| News position match status                                       |
//+------------------------------------------------------------------+
//| Describes whether an open position is affected by the selected   |
//| Economic Calendar event.                                         |
//+------------------------------------------------------------------+
enum ENUM_NEWS_POSITION_STATUS
  {
   NEWS_POSITION_NOT_AFFECTED = 0, // Position does not use the event currency
   NEWS_POSITION_AFFECTED,         // Position is exposed to the event currency
   NEWS_POSITION_UNSUPPORTED       // Position is outside current Forex/XAUUSD scope
  };

//+------------------------------------------------------------------+
//| News holding status                                              |
//+------------------------------------------------------------------+
//| Describes the account's current holding-rule condition around    |
//| the selected Economic Calendar event.                            |
//+------------------------------------------------------------------+
enum ENUM_NEWS_HOLDING_STATUS
  {
   NEWS_HOLDING_CLEAR = 0,        // No active holding restriction
   NEWS_HOLDING_ALLOWED,          // Restricted window active but holding is permitted
   NEWS_HOLDING_WARNING,          // Event is approaching and affected positions exist
   NEWS_HOLDING_PROTECTION        // Restricted window active and protection is required
  };

//+------------------------------------------------------------------+
//| Protection action                                                |
//+------------------------------------------------------------------+
//| Defines what Prop Firm Guard should do when a monitored rule     |
//| requires protective action.                                      |
//+------------------------------------------------------------------+
enum ENUM_PROTECTION_ACTION
  {
   PROTECTION_WARN_ONLY = 0,       // Report the condition without closing positions
   PROTECTION_CLOSE_AFFECTED,      // Close positions affected by the triggering rule
   PROTECTION_CLOSE_ALL            // Close every open account position
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "General"
input int    InpTimerSeconds            = 1;      // Dashboard update interval in seconds
input int    InpDashboardX              = 10;     // Dashboard horizontal position
input int    InpDashboardY              = 105;    // Dashboard vertical position
input bool   InpEnableAlerts            = true;   // Enable terminal alerts
input bool   InpEnablePushNotifications = false;  // Enable mobile push notifications

input group "Prop Firm Rules"
input double InpInitialAccountBalance  = 100000.0; // Initial prop-firm account balance
input double InpDailyDrawdownPercent   = 5.0;     // Maximum permitted daily drawdown
input double InpOverallDrawdownPercent = 10.0;    // Maximum permitted overall drawdown
input double InpProfitTargetPercent    = 8.0;     // Required profit target

input group "Warning Levels"
input double InpWarningLevelPercent  = 70.0;      // Loss limit usage that triggers warning
input double InpCriticalLevelPercent = 90.0;      // Loss limit usage that triggers critical state

input group "News Filter"
input bool   InpEnableNewsFilter       = true;    // Enable economic news monitoring
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum monitored importance
input int    InpMinutesBeforeNews      = 10;      // Restricted minutes before news
input int    InpMinutesAfterNews       = 10;      // Restricted minutes after news
input bool   InpAllowNewsHolding       = true;    // Allow positions to remain open during news

input group "Protection Actions"
input ENUM_PROTECTION_ACTION InpDailyDrawdownAction   = PROTECTION_WARN_ONLY; // Daily breach action
input ENUM_PROTECTION_ACTION InpOverallDrawdownAction = PROTECTION_WARN_ONLY; // Overall breach action
input ENUM_PROTECTION_ACTION InpNewsRestrictionAction = PROTECTION_WARN_ONLY; // News restriction action

//+------------------------------------------------------------------+
//| Account state structure                                          |
//+------------------------------------------------------------------+
//| Holds the live account values required by the monitoring logic.  |
//+------------------------------------------------------------------+
struct SAccountState
  {
   long                    login;       // Trading account login number
   double                  balance;     // Current account balance
   double                  equity;      // Current account equity
   double                  floatingPL;  // Current floating profit or loss
   ENUM_COMPLIANCE_STATUS  status;      // Current overall compliance status
  };

//+------------------------------------------------------------------+
//| Account settings structure                                       |
//+------------------------------------------------------------------+
//| Stores the main prop-firm rules associated with this account.    |
//+------------------------------------------------------------------+
struct SAccountSettings
  {
   long              accountLogin;           // Trading account login
   string            accountServer;          // Broker trading server
   double            initialBalance;         // Initial prop-firm account balance
   double            dailyDrawdownPercent;   // Maximum daily drawdown
   double            overallDrawdownPercent; // Maximum overall drawdown
   double            profitTargetPercent;    // Required profit target
   datetime          updatedAt;              // Last settings update time
  };

//+------------------------------------------------------------------+
//| Daily session structure                                          |
//+------------------------------------------------------------------+
//| Represents the persistent state associated with one trading day. |
//+------------------------------------------------------------------+
struct SDailySession
  {
   long              accountLogin;
   string            accountServer;
   string            tradingDate;
   double            startingBalance;
   double            startingEquity;
   bool              balanceConfirmed;
   double            latestBalance;
   double            latestEquity;
   double            dailyLoss;
   double            maximumDailyLossReached;
   double            targetProgress;
   string            sessionStatus;
   datetime          createdAt;
   datetime          updatedAt;
  };

//+------------------------------------------------------------------+
//| Daily drawdown structure                                         |
//+------------------------------------------------------------------+
//| Holds the calculated daily risk values for the active session.   |
//+------------------------------------------------------------------+
struct SDailyDrawdownState
  {
   double                  startingBalance;        // Confirmed daily starting balance
   double                  currentEquity;          // Current live account equity
   double                  maximumDailyLoss;       // Maximum money that may be lost today
   double                  currentDailyLoss;       // Current loss measured from starting balance
   double                  drawdownPercent;        // Current loss as percentage of starting balance
   double                  limitUsagePercent;      // Percentage of daily loss allowance already used
   double                  remainingAllowance;     // Money remaining before daily breach
   ENUM_COMPLIANCE_STATUS  status;                 // Current daily drawdown status
  };

//+------------------------------------------------------------------+
//| Overall drawdown structure                                       |
//+------------------------------------------------------------------+
//| Holds the live calculations for the static overall loss rule.    |
//+------------------------------------------------------------------+
struct SOverallDrawdownState
  {
   double                  initialBalance;         // Initial prop-firm account balance
   double                  currentEquity;          // Current live account equity
   double                  maximumOverallLoss;     // Maximum permitted overall loss
   double                  overallFloor;           // Minimum permitted account equity
   double                  currentOverallLoss;     // Current loss from initial balance
   double                  limitUsagePercent;      // Percentage of overall allowance used
   double                  remainingAllowance;     // Money remaining before breach
   ENUM_COMPLIANCE_STATUS  status;                 // Current overall drawdown status
  };

//+------------------------------------------------------------------+
//| Profit target structure                                          |
//+------------------------------------------------------------------+
//| Holds the live calculations used to track challenge progress.    |
//+------------------------------------------------------------------+
struct SProfitTargetState
  {
   double              initialBalance;        // Initial prop-firm account balance
   double              currentBalance;        // Current realized account balance
   double              targetAmount;          // Profit required in account currency
   double              targetBalance;         // Balance required to complete the target
   double              currentProfit;         // Realized profit above initial balance
   double              progressPercent;       // Percentage of target already completed
   double              remainingProfit;       // Profit still required to reach target
   ENUM_TARGET_STATUS  status;                // Current target progress state
  };

//+------------------------------------------------------------------+
//| News monitoring structure                                        |
//+------------------------------------------------------------------+
struct SNewsState
  {
   bool                            hasExposure;              // Whether supported open positions exist
   int                             monitoredCurrencies;      // Number of unique monitored currencies
   string                          currencyList;             // Monitored currency list
   bool                            eventFound;               // Whether a relevant event was located
   string                          eventCurrency;            // Currency affected by selected event
   ulong                           eventId;                  // Economic Calendar event identifier
   string                          eventName;                // Economic event name
   ENUM_CALENDAR_EVENT_IMPORTANCE  importance;               // Event importance
   datetime                        eventTime;                // Event time in trade-server time
   long                            secondsToEvent;           // Signed distance to event
   datetime                        restrictionStart;         // Beginning of restricted news window
   datetime                        restrictionEnd;           // End of restricted news window
   bool                            restrictedWindow;         // Whether restriction is currently active
   int                             affectedPositions;        // Positions affected by selected event
   int                             protectionPositions;      // Affected positions requiring protection
   ENUM_NEWS_STATUS                status;                   // Current news-monitoring status
   ENUM_NEWS_HOLDING_STATUS        holdingStatus;            // Current news-holding condition
  };

//+------------------------------------------------------------------+
//| News position match structure                                    |
//+------------------------------------------------------------------+
struct SNewsPositionMatch
  {
   ulong                       ticket;             // Position ticket
   string                      symbol;             // Position symbol
   string                      currency1;          // First relevant currency
   string                      currency2;          // Second relevant currency
   ENUM_NEWS_POSITION_STATUS   status;             // Event-currency classification
   bool                        protectionRequired; // Whether protection is required
  };

//+------------------------------------------------------------------+
//| Alert state                                                      |
//+------------------------------------------------------------------+
//| Remembers which conditions have already generated notifications. |
//+------------------------------------------------------------------+
struct SAlertState
  {
   ENUM_COMPLIANCE_STATUS dailyDrawdownStatus;
   ENUM_COMPLIANCE_STATUS overallDrawdownStatus;
   ENUM_TARGET_STATUS     profitTargetStatus;
   ulong                  newsEventId;
   bool                   newsApproachAlerted;
   bool                   newsRestrictedAlerted;
   string                 dashboardMessage;
  };

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
SAccountState         g_accountState;                      // Latest monitored account state
SAccountSettings      g_accountSettings;                   // Persisted prop-firm settings
SDailySession         g_dailySession;                      // Current trading-day record
SDailyDrawdownState   g_dailyDrawdown;                     // Current daily drawdown calculations
SOverallDrawdownState g_overallDrawdown;                   // Current overall drawdown calculations
SProfitTargetState    g_profitTarget;                      // Current profit-target calculations
SNewsState            g_newsState;                        // Current economic news state
SNewsPositionMatch    g_newsPositionMatches[];            // Classification of open positions
SAlertState           g_alertState;                       // Alert transition memory

CTrade                g_trade;                            // Synchronous trade execution helper

string                g_startBalanceEdit = "PFG_StartBalanceEdit"; // Starting balance input field
string                g_confirmButton = "PFG_ConfirmBalance";       // Daily balance confirmation button
string                g_databaseName = "prop_firm_compliance.sqlite"; // SQLite database file

int                   g_database = INVALID_HANDLE;         // Active SQLite database handle
bool                  g_hasDailySession = false;           // Whether a daily session is loaded

bool                  g_dailyBreachWarned = false;         // Prevent repeated daily breach warnings
bool                  g_overallBreachWarned = false;       // Prevent repeated overall breach warnings
ulong                 g_lastNewsWarnedEventId = 0;         // Prevent repeated warning for same news event

datetime g_lastRuntimeDatabaseUpdate = 0;              // Last successful runtime database update

string g_objectPrefix = "PFG_";                        // Prefix used by dashboard objects

//+------------------------------------------------------------------+
//| Validate compliance inputs                                       |
//+------------------------------------------------------------------+
bool ValidateComplianceInputs()
  {
//--- Validate the initial account balance
   if(InpInitialAccountBalance <= 0.0)
     {
      Print("Prop Firm Guard: Initial account balance must be greater than zero.");

      return(false);
     }

//--- Validate the daily drawdown percentage
   if(InpDailyDrawdownPercent <= 0.0 ||
      InpDailyDrawdownPercent > 100.0)
     {
      Print("Prop Firm Guard: Daily drawdown percentage must be between 0 and 100.");

      return(false);
     }

//--- Validate the overall drawdown percentage
   if(InpOverallDrawdownPercent <= 0.0 ||
      InpOverallDrawdownPercent > 100.0)
     {
      Print("Prop Firm Guard: Overall drawdown percentage must be between 0 and 100.");

      return(false);
     }

//--- Validate the profit target percentage
   if(InpProfitTargetPercent <= 0.0 ||
      InpProfitTargetPercent > 100.0)
     {
      Print("Prop Firm Guard: Profit target percentage must be between 0 and 100.");

      return(false);
     }

//--- Validate the warning threshold
   if(InpWarningLevelPercent <= 0.0 ||
      InpWarningLevelPercent >= InpCriticalLevelPercent)
     {
      Print("Prop Firm Guard: Warning level must be greater than 0 and below the critical level.");

      return(false);
     }

//--- Validate the critical threshold
   if(InpCriticalLevelPercent <= InpWarningLevelPercent ||
      InpCriticalLevelPercent >= 100.0)
     {
      Print("Prop Firm Guard: Critical level must be above the warning level and below 100.");

      return(false);
     }

//--- Validate the news restriction windows
   if(InpMinutesBeforeNews < 0 ||
      InpMinutesAfterNews < 0)
     {
      Print("Prop Firm Guard: News restriction minutes cannot be negative.");

      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Set chart integer property                                       |
//+------------------------------------------------------------------+
bool SetChartIntegerProperty(const ENUM_CHART_PROPERTY_INTEGER property,
                             const long                        value)
  {
//--- Apply the requested property to the current chart
   ResetLastError();

   if(!ChartSetInteger(0,
                       property,
                       value))
     {
      Print("Prop Firm Guard: Could not set chart property ",
            EnumToString(property),
            ". Error: ",
            GetLastError());

      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Configure Prop Firm Guard chart appearance                       |
//+------------------------------------------------------------------+
bool ConfigureChartAppearance()
  {
//--- Use a light background with dark chart text
   if(!SetChartIntegerProperty(CHART_COLOR_BACKGROUND,
                               clrWhiteSmoke))
      return(false);

   if(!SetChartIntegerProperty(CHART_COLOR_FOREGROUND,
                               clrBlack))
      return(false);

//--- Remove the chart grid behind the dashboard
   if(!SetChartIntegerProperty(CHART_SHOW_GRID,
                               false))
      return(false);

//--- Display price movement as candlesticks
   if(!SetChartIntegerProperty(CHART_MODE,
                               CHART_CANDLES))
      return(false);

//--- Use green for bullish candles and bars
   if(!SetChartIntegerProperty(CHART_COLOR_CANDLE_BULL,
                               clrGreen))
      return(false);

   if(!SetChartIntegerProperty(CHART_COLOR_CHART_UP,
                               clrGreen))
      return(false);

//--- Use red for bearish candles and bars
   if(!SetChartIntegerProperty(CHART_COLOR_CANDLE_BEAR,
                               clrRed))
      return(false);

   if(!SetChartIntegerProperty(CHART_COLOR_CHART_DOWN,
                               clrRed))
      return(false);

//--- Keep the line chart representation neutral
   if(!SetChartIntegerProperty(CHART_COLOR_CHART_LINE,
                               clrBlack))
      return(false);

//--- Distinguish Bid and Ask prices
   if(!SetChartIntegerProperty(CHART_COLOR_BID,
                               clrGreen))
      return(false);

   if(!SetChartIntegerProperty(CHART_COLOR_ASK,
                               clrRed))
      return(false);

//--- Keep the last price visually neutral
   if(!SetChartIntegerProperty(CHART_COLOR_LAST,
                               clrBlack))
      return(false);

//--- Highlight Stop Loss and Take Profit levels
   if(!SetChartIntegerProperty(CHART_COLOR_STOP_LEVEL,
                               clrRed))
      return(false);

//--- Display and allow interaction with trade levels
   if(!SetChartIntegerProperty(CHART_SHOW_TRADE_LEVELS,
                               true))
      return(false);

   if(!SetChartIntegerProperty(CHART_DRAG_TRADE_LEVELS,
                               true))
      return(false);

//--- Keep the One Click Trading panel available
   if(!SetChartIntegerProperty(CHART_SHOW_ONE_CLICK,
                               true))
      return(false);

//--- Apply the completed chart presentation
   ChartRedraw(0);

   return(true);
  }

//+------------------------------------------------------------------+
//| Update account state                                             |
//+------------------------------------------------------------------+
void UpdateAccountState()
  {
//--- Read the current account values
   g_accountState.login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_accountState.balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_accountState.equity = AccountInfoDouble(ACCOUNT_EQUITY);

//--- Derive the current floating profit or loss
   g_accountState.floatingPL = g_accountState.equity - g_accountState.balance;

//--- Initialize compliance status before rule calculations are added
   g_accountState.status = COMPLIANCE_SAFE;
  }

//+------------------------------------------------------------------+
//| Calculate daily drawdown                                         |
//+------------------------------------------------------------------+
void CalculateDailyDrawdown()
  {
//--- Reset the state until the daily starting balance is confirmed
   if(!g_dailySession.balanceConfirmed ||
      g_dailySession.startingBalance <= 0.0)
     {
      g_dailyDrawdown.startingBalance    = 0.0;
      g_dailyDrawdown.currentEquity      = g_accountState.equity;
      g_dailyDrawdown.maximumDailyLoss   = 0.0;
      g_dailyDrawdown.currentDailyLoss   = 0.0;
      g_dailyDrawdown.drawdownPercent    = 0.0;
      g_dailyDrawdown.limitUsagePercent  = 0.0;
      g_dailyDrawdown.remainingAllowance = 0.0;
      g_dailyDrawdown.status             = COMPLIANCE_SAFE;

      return;
     }

//--- Read the active daily reference and current equity
   g_dailyDrawdown.startingBalance = g_dailySession.startingBalance;
   g_dailyDrawdown.currentEquity   = g_accountState.equity;

//--- Calculate the permitted daily loss
   g_dailyDrawdown.maximumDailyLoss =
      g_dailyDrawdown.startingBalance *
      g_accountSettings.dailyDrawdownPercent / 100.0;

//--- Calculate the current daily loss
   g_dailyDrawdown.currentDailyLoss =
      g_dailyDrawdown.startingBalance -
      g_dailyDrawdown.currentEquity;

   if(g_dailyDrawdown.currentDailyLoss < 0.0)
      g_dailyDrawdown.currentDailyLoss = 0.0;

//--- Calculate the loss percentage
   g_dailyDrawdown.drawdownPercent =
      g_dailyDrawdown.currentDailyLoss /
      g_dailyDrawdown.startingBalance * 100.0;

//--- Calculate daily limit usage
   if(g_dailyDrawdown.maximumDailyLoss > 0.0)
     {
      g_dailyDrawdown.limitUsagePercent =
         g_dailyDrawdown.currentDailyLoss /
         g_dailyDrawdown.maximumDailyLoss * 100.0;
     }
   else
     {
      g_dailyDrawdown.limitUsagePercent = 0.0;
     }

//--- Calculate the remaining allowance
   g_dailyDrawdown.remainingAllowance =
      g_dailyDrawdown.maximumDailyLoss -
      g_dailyDrawdown.currentDailyLoss;

   if(g_dailyDrawdown.remainingAllowance < 0.0)
      g_dailyDrawdown.remainingAllowance = 0.0;

//--- Classify the current daily drawdown state
   if(g_dailyDrawdown.limitUsagePercent >= 100.0)
      g_dailyDrawdown.status = COMPLIANCE_BREACHED;
   else
      if(g_dailyDrawdown.limitUsagePercent >= InpCriticalLevelPercent)
         g_dailyDrawdown.status = COMPLIANCE_CRITICAL;
      else
         if(g_dailyDrawdown.limitUsagePercent >= InpWarningLevelPercent)
            g_dailyDrawdown.status = COMPLIANCE_WARNING;
         else
            g_dailyDrawdown.status = COMPLIANCE_SAFE;
  }

//+------------------------------------------------------------------+
//| Calculate overall drawdown                                       |
//+------------------------------------------------------------------+
void CalculateOverallDrawdown()
  {
//--- Read the fixed challenge reference and current equity
   g_overallDrawdown.initialBalance = g_accountSettings.initialBalance;
   g_overallDrawdown.currentEquity  = g_accountState.equity;

//--- Calculate the maximum permitted overall loss
   g_overallDrawdown.maximumOverallLoss =
      g_overallDrawdown.initialBalance *
      g_accountSettings.overallDrawdownPercent / 100.0;

//--- Calculate the static overall equity floor
   g_overallDrawdown.overallFloor =
      g_overallDrawdown.initialBalance -
      g_overallDrawdown.maximumOverallLoss;

//--- Calculate the current loss from the initial balance
   g_overallDrawdown.currentOverallLoss =
      g_overallDrawdown.initialBalance -
      g_overallDrawdown.currentEquity;

   if(g_overallDrawdown.currentOverallLoss < 0.0)
      g_overallDrawdown.currentOverallLoss = 0.0;

//--- Calculate overall limit usage
   if(g_overallDrawdown.maximumOverallLoss > 0.0)
     {
      g_overallDrawdown.limitUsagePercent =
         g_overallDrawdown.currentOverallLoss /
         g_overallDrawdown.maximumOverallLoss * 100.0;
     }
   else
     {
      g_overallDrawdown.limitUsagePercent = 0.0;
     }

//--- Calculate the remaining overall allowance
   g_overallDrawdown.remainingAllowance =
      g_overallDrawdown.maximumOverallLoss -
      g_overallDrawdown.currentOverallLoss;

   if(g_overallDrawdown.remainingAllowance < 0.0)
      g_overallDrawdown.remainingAllowance = 0.0;

//--- Classify the current overall drawdown state
   if(g_overallDrawdown.limitUsagePercent >= 100.0)
      g_overallDrawdown.status = COMPLIANCE_BREACHED;
   else
      if(g_overallDrawdown.limitUsagePercent >= InpCriticalLevelPercent)
         g_overallDrawdown.status = COMPLIANCE_CRITICAL;
      else
         if(g_overallDrawdown.limitUsagePercent >= InpWarningLevelPercent)
            g_overallDrawdown.status = COMPLIANCE_WARNING;
         else
            g_overallDrawdown.status = COMPLIANCE_SAFE;
  }

//+------------------------------------------------------------------+
//| Calculate profit target                                          |
//+------------------------------------------------------------------+
void CalculateProfitTarget()
  {
//--- Read the fixed challenge reference and realized balance
   g_profitTarget.initialBalance = g_accountSettings.initialBalance;
   g_profitTarget.currentBalance = g_accountState.balance;

//--- Calculate the required profit and target balance
   g_profitTarget.targetAmount =
      g_profitTarget.initialBalance *
      g_accountSettings.profitTargetPercent / 100.0;

   g_profitTarget.targetBalance =
      g_profitTarget.initialBalance +
      g_profitTarget.targetAmount;

//--- Calculate realized profit above the initial balance
   g_profitTarget.currentProfit =
      g_profitTarget.currentBalance -
      g_profitTarget.initialBalance;

   if(g_profitTarget.currentProfit < 0.0)
      g_profitTarget.currentProfit = 0.0;

//--- Calculate target progress
   if(g_profitTarget.targetAmount > 0.0)
     {
      g_profitTarget.progressPercent =
         g_profitTarget.currentProfit /
         g_profitTarget.targetAmount * 100.0;
     }
   else
     {
      g_profitTarget.progressPercent = 0.0;
     }

   if(g_profitTarget.progressPercent > 100.0)
      g_profitTarget.progressPercent = 100.0;

//--- Calculate the remaining required profit
   g_profitTarget.remainingProfit =
      g_profitTarget.targetAmount -
      g_profitTarget.currentProfit;

   if(g_profitTarget.remainingProfit < 0.0)
      g_profitTarget.remainingProfit = 0.0;

//--- Classify the current target state
   if(g_profitTarget.currentBalance >= g_profitTarget.targetBalance)
      g_profitTarget.status = TARGET_REACHED;
   else
      if(g_profitTarget.progressPercent >= 90.0)
         g_profitTarget.status = TARGET_NEARING;
      else
         g_profitTarget.status = TARGET_IN_PROGRESS;
  }

//+------------------------------------------------------------------+
//| Initialize news state                                            |
//+------------------------------------------------------------------+
void InitializeNewsState()
  {
//--- Clear account-exposure information
   g_newsState.hasExposure = false;
   g_newsState.monitoredCurrencies = 0;
   g_newsState.currencyList = "";

//--- Clear the previously selected calendar event
   g_newsState.eventFound = false;
   g_newsState.eventCurrency = "";
   g_newsState.eventId = 0;
   g_newsState.eventName = "";
   g_newsState.importance = CALENDAR_IMPORTANCE_NONE;
   g_newsState.eventTime = 0;

//--- Reset event timing and restriction-window state
   g_newsState.secondsToEvent = 0;
   g_newsState.restrictionStart = 0;
   g_newsState.restrictionEnd = 0;
   g_newsState.restrictedWindow = false;

//--- Set the initial monitoring condition
   g_newsState.status =
      InpEnableNewsFilter ? NEWS_NO_EXPOSURE : NEWS_DISABLED;
  }

//+------------------------------------------------------------------+
//| Initialize alert state                                           |
//+------------------------------------------------------------------+
void InitializeAlertState()
  {
//--- Synchronize financial alert memory with the current rule states
   g_alertState.dailyDrawdownStatus = g_dailyDrawdown.status;
   g_alertState.overallDrawdownStatus = g_overallDrawdown.status;
   g_alertState.profitTargetStatus = g_profitTarget.status;

//--- Clear Economic Calendar notification tracking
   g_alertState.newsEventId = 0;
   g_alertState.newsApproachAlerted = false;
   g_alertState.newsRestrictedAlerted = false;

//--- Start the dashboard without a retained alert message
   g_alertState.dashboardMessage = "";
  }

//+------------------------------------------------------------------+
//| Send guard notification                                          |
//+------------------------------------------------------------------+
void SendGuardNotification(const string message)
  {
//--- Record every generated notification in the terminal log
   Print("Prop Firm Guard: ",
         message);

//--- Show a terminal alert when enabled
   if(InpEnableAlerts)
      Alert("Prop Firm Guard: ",
            message);

//--- Stop here when mobile push notifications are disabled
   if(!InpEnablePushNotifications)
      return;

//--- Confirm that push notifications are enabled in MetaTrader
   if(!TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
     {
      Print("Prop Firm Guard: Push notifications are enabled in the EA ",
            "but disabled in the terminal settings.");

      return;
     }

//--- Send the optional mobile notification
   ResetLastError();

   if(!SendNotification("Prop Firm Guard: " + message))
     {
      Print("Prop Firm Guard: Could not send push notification. Error: ",
            GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Convert calendar importance to text                              |
//+------------------------------------------------------------------+
string CalendarImportanceToString(
   const ENUM_CALENDAR_EVENT_IMPORTANCE importance)
  {
   switch(importance)
     {
      case CALENDAR_IMPORTANCE_HIGH:
         return("HIGH");

      case CALENDAR_IMPORTANCE_MODERATE:
         return("MODERATE");

      case CALENDAR_IMPORTANCE_LOW:
         return("LOW");

      case CALENDAR_IMPORTANCE_NONE:
      default:
         return("NONE");
     }
  }

//+------------------------------------------------------------------+
//| Build daily drawdown alert                                       |
//+------------------------------------------------------------------+
string BuildDailyDrawdownAlert(const ENUM_COMPLIANCE_STATUS status)
  {
   switch(status)
     {
      case COMPLIANCE_WARNING:
         return("Daily drawdown reached WARNING level.");

      case COMPLIANCE_CRITICAL:
         return("CRITICAL: Only " +
                DoubleToString(g_dailyDrawdown.remainingAllowance, 2) +
                " remains before the daily loss limit.");

      case COMPLIANCE_BREACHED:
         return("Daily drawdown limit breached.");

      case COMPLIANCE_SAFE:
      default:
         return("");
     }
  }

//+------------------------------------------------------------------+
//| Build overall drawdown alert                                     |
//+------------------------------------------------------------------+
string BuildOverallDrawdownAlert(const ENUM_COMPLIANCE_STATUS status)
  {
   switch(status)
     {
      case COMPLIANCE_WARNING:
         return("Overall drawdown reached WARNING level.");

      case COMPLIANCE_CRITICAL:
         return("CRITICAL: Only " +
                DoubleToString(g_overallDrawdown.remainingAllowance, 2) +
                " remains before the overall loss limit.");

      case COMPLIANCE_BREACHED:
         return("Overall drawdown limit breached.");

      case COMPLIANCE_SAFE:
      default:
         return("");
     }
  }

//+------------------------------------------------------------------+
//| Check daily drawdown alert                                       |
//+------------------------------------------------------------------+
void CheckDailyDrawdownAlert()
  {
//--- Daily alerts require a confirmed session baseline
   if(!g_dailySession.balanceConfirmed)
      return;

//--- An unchanged state has already been observed
   if(g_dailyDrawdown.status == g_alertState.dailyDrawdownStatus)
      return;

//--- Remember the new state before deciding whether it needs a message
   g_alertState.dailyDrawdownStatus = g_dailyDrawdown.status;

   string message = BuildDailyDrawdownAlert(g_dailyDrawdown.status);

   if(message == "")
      return;

//--- Report the newly entered drawdown state
   SendGuardNotification(message);
  }

//+------------------------------------------------------------------+
//| Check overall drawdown alert                                     |
//+------------------------------------------------------------------+
void CheckOverallDrawdownAlert()
  {
//--- Ignore an unchanged overall drawdown state
   if(g_overallDrawdown.status == g_alertState.overallDrawdownStatus)
      return;

//--- Store the transition before generating its message
   g_alertState.overallDrawdownStatus = g_overallDrawdown.status;

   string message = BuildOverallDrawdownAlert(g_overallDrawdown.status);

   if(message == "")
      return;

//--- Report the newly entered drawdown state
   SendGuardNotification(message);
  }

//+------------------------------------------------------------------+
//| Check profit target alert                                        |
//+------------------------------------------------------------------+
void CheckProfitTargetAlert()
  {
//--- Ignore an unchanged target state
   if(g_profitTarget.status == g_alertState.profitTargetStatus)
      return;

//--- Remember the new target state
   g_alertState.profitTargetStatus = g_profitTarget.status;

//--- Only completion produces a target notification
   if(g_profitTarget.status != TARGET_REACHED)
      return;

   SendGuardNotification("Profit target reached.");
  }

//+------------------------------------------------------------------+
//| Check economic news alerts                                       |
//+------------------------------------------------------------------+
void CheckNewsAlert()
  {
//--- News alerts require a relevant event and affected exposure
   if(!InpEnableNewsFilter ||
      !g_newsState.eventFound ||
      g_newsState.affectedPositions == 0)
      return;

//--- Give every newly selected event a fresh notification state
   if(g_alertState.newsEventId != g_newsState.eventId)
     {
      g_alertState.newsEventId = g_newsState.eventId;
      g_alertState.newsApproachAlerted = false;
      g_alertState.newsRestrictedAlerted = false;
     }

   long warningThreshold =
      (long)InpMinutesBeforeNews * 60;

//--- Issue one advance warning inside the configured pre-news interval
   if(g_newsState.secondsToEvent > 0 &&
      g_newsState.secondsToEvent <= warningThreshold &&
      !g_alertState.newsApproachAlerted)
     {
      string message =
         CalendarImportanceToString(g_newsState.importance) +
         "-impact " +
         g_newsState.eventCurrency +
         " news in " +
         IntegerToString((int)MathCeil((double)g_newsState.secondsToEvent / 60.0)) +
         " minute(s): " +
         g_newsState.eventName +
         ".";

      g_alertState.newsApproachAlerted = true;

      SendGuardNotification(message);
     }

//--- Report prohibited holding once the active restriction requires protection
   if(g_newsState.holdingStatus == NEWS_HOLDING_PROTECTION &&
      !g_alertState.newsRestrictedAlerted)
     {
      string message =
         "News holding restriction active for " +
         g_newsState.eventCurrency +
         " " +
         g_newsState.eventName +
         ".";

      g_alertState.newsRestrictedAlerted = true;

      SendGuardNotification(message);
     }
  }

//+------------------------------------------------------------------+
//| Manage alerts                                                    |
//+------------------------------------------------------------------+
void ManageAlerts()
  {
//--- Check financial-rule transitions
   CheckDailyDrawdownAlert();
   CheckOverallDrawdownAlert();
   CheckProfitTargetAlert();

//--- Check event-specific economic-news transitions
   CheckNewsAlert();
  }

//+------------------------------------------------------------------+
//| Check whether currency already exists in array                    |
//+------------------------------------------------------------------+
bool CurrencyExists(const string &currencies[],
                    const string currency)
  {
   int count = ArraySize(currencies);

//--- Search the current currency set
   for(int i = 0; i < count; i++)
     {
      if(currencies[i] == currency)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Add unique currency to array                                     |
//+------------------------------------------------------------------+
bool AddUniqueCurrency(string &currencies[],
                       const string currency)
  {
//--- Ignore an empty currency value
   if(currency == "")
      return(true);

//--- Keep each monitored currency only once
   if(CurrencyExists(currencies, currency))
      return(true);

   int currentSize = ArraySize(currencies);

//--- Extend the currency array
   if(ArrayResize(currencies, currentSize + 1) != currentSize + 1)
     {
      Print("Prop Firm Guard: Could not expand monitored currency array.");

      return(false);
     }

   currencies[currentSize] = currency;

   return(true);
  }

//+------------------------------------------------------------------+
//| Get symbol currencies relevant to news                           |
//+------------------------------------------------------------------+
bool GetSymbolNewsCurrencies(const string symbol,
                             string &currency1,
                             string &currency2)
  {
   string baseCurrency;
   string profitCurrency;
   long calculationMode = 0;

   currency1 = "";
   currency2 = "";

//--- Read the currencies defined by the broker for this symbol
   ResetLastError();

   if(!SymbolInfoString(symbol,
                        SYMBOL_CURRENCY_BASE,
                        baseCurrency))
     {
      Print("Prop Firm Guard: Could not read base currency for ",
            symbol,
            ". Error: ",
            GetLastError());

      return(false);
     }

   ResetLastError();

   if(!SymbolInfoString(symbol,
                        SYMBOL_CURRENCY_PROFIT,
                        profitCurrency))
     {
      Print("Prop Firm Guard: Could not read profit currency for ",
            symbol,
            ". Error: ",
            GetLastError());

      return(false);
     }

//--- Treat XAUUSD as USD calendar exposure
   if(baseCurrency == "XAU" &&
      profitCurrency == "USD")
     {
      currency1 = "USD";

      return(true);
     }

//--- Read the symbol's trading calculation model
   ResetLastError();

   if(!SymbolInfoInteger(symbol,
                         SYMBOL_TRADE_CALC_MODE,
                         calculationMode))
     {
      Print("Prop Firm Guard: Could not read calculation mode for ",
            symbol,
            ". Error: ",
            GetLastError());

      return(false);
     }

//--- Ignore instruments outside the supported Forex calculation modes
   if(calculationMode != SYMBOL_CALC_MODE_FOREX &&
      calculationMode != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)
      return(true);

   currency1 = baseCurrency;
   currency2 = profitCurrency;

   return(true);
  }

//+------------------------------------------------------------------+
//| Match open positions to selected news event                      |
//+------------------------------------------------------------------+
void MatchOpenPositionsToNews()
  {
//--- Remove classifications from the previous monitoring cycle
   ArrayResize(g_newsPositionMatches, 0);

//--- Position matching requires an actual selected calendar event
   if(!g_newsState.eventFound ||
      g_newsState.eventCurrency == "")
      return;

   int totalPositions = PositionsTotal();

//--- Classify every currently open account position
   for(int i = 0; i < totalPositions; i++)
     {
      ResetLastError();

      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
        {
         Print("Prop Firm Guard: Could not retrieve position ticket at index ",
               i,
               ". Error: ",
               GetLastError());

         continue;
        }

      string symbol;

      if(!PositionGetString(POSITION_SYMBOL,
                            symbol))
        {
         Print("Prop Firm Guard: Could not retrieve symbol for position ",
               ticket,
               ". Error: ",
               GetLastError());

         continue;
        }

      string currency1;
      string currency2;

      if(!GetSymbolNewsCurrencies(symbol,
                                  currency1,
                                  currency2))
         continue;

      SNewsPositionMatch match;

      match.ticket = ticket;
      match.symbol = symbol;
      match.currency1 = currency1;
      match.currency2 = currency2;
      match.status = NEWS_POSITION_NOT_AFFECTED;
      match.protectionRequired = false;

      //--- Classify the position against the selected event currency
      if(currency1 == "" &&
         currency2 == "")
        {
         match.status = NEWS_POSITION_UNSUPPORTED;
        }
      else
         if(currency1 == g_newsState.eventCurrency ||
            currency2 == g_newsState.eventCurrency)
           {
            match.status = NEWS_POSITION_AFFECTED;
           }

      int currentSize = ArraySize(g_newsPositionMatches);

      //--- Store the ticket-level classification
      if(ArrayResize(g_newsPositionMatches,
                     currentSize + 1) != currentSize + 1)
        {
         Print("Prop Firm Guard: Could not expand news position match array.");

         return;
        }

      g_newsPositionMatches[currentSize] = match;
     }
  }

//+------------------------------------------------------------------+
//| Evaluate news holding rules                                      |
//+------------------------------------------------------------------+
void EvaluateNewsHoldingRules()
  {
//--- Reset the account-level holding result
   g_newsState.affectedPositions = 0;
   g_newsState.protectionPositions = 0;
   g_newsState.holdingStatus = NEWS_HOLDING_CLEAR;

   int totalMatches = ArraySize(g_newsPositionMatches);

//--- Stop when no selected event or classified positions exist
   if(!g_newsState.eventFound ||
      totalMatches == 0)
      return;

//--- Count positions affected by the selected event
   for(int i = 0; i < totalMatches; i++)
     {
      g_newsPositionMatches[i].protectionRequired = false;

      if(g_newsPositionMatches[i].status == NEWS_POSITION_AFFECTED)
         g_newsState.affectedPositions++;
     }

//--- No affected positions means no holding restriction applies
   if(g_newsState.affectedPositions == 0)
      return;

//--- Respect configurations that permit positions to remain open
   if(InpAllowNewsHolding)
     {
      if(g_newsState.restrictedWindow)
         g_newsState.holdingStatus = NEWS_HOLDING_ALLOWED;
      else
         g_newsState.holdingStatus = NEWS_HOLDING_WARNING;

      return;
     }

//--- Warn while affected positions approach the restricted window
   if(!g_newsState.restrictedWindow)
     {
      g_newsState.holdingStatus = NEWS_HOLDING_WARNING;

      return;
     }

//--- Mark affected positions when holding is prohibited in the window
   for(int i = 0; i < totalMatches; i++)
     {
      if(g_newsPositionMatches[i].status != NEWS_POSITION_AFFECTED)
         continue;

      g_newsPositionMatches[i].protectionRequired = true;
      g_newsState.protectionPositions++;
     }

   g_newsState.holdingStatus = NEWS_HOLDING_PROTECTION;
  }

//+------------------------------------------------------------------+
//| Update news position matches                                     |
//+------------------------------------------------------------------+
void UpdateNewsPositionMatches()
  {
//--- Classify all currently open positions against the selected event
   MatchOpenPositionsToNews();

//--- Apply the configured holding rule to those classifications
   EvaluateNewsHoldingRules();
  }

//+------------------------------------------------------------------+
//| Add currencies exposed by position symbol                        |
//+------------------------------------------------------------------+
bool AddPositionCurrencies(const string symbol,
                           string &currencies[])
  {
   string currency1;
   string currency2;

//--- Determine the supported news currencies for the position symbol
   if(!GetSymbolNewsCurrencies(symbol,
                               currency1,
                               currency2))
      return(false);

//--- Ignore instruments outside the supported monitoring scope
   if(currency1 == "" &&
      currency2 == "")
      return(true);

//--- Add the exposed currencies without creating duplicates
   if(!AddUniqueCurrency(currencies, currency1))
      return(false);

   if(!AddUniqueCurrency(currencies, currency2))
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Collect currencies from active positions                         |
//+------------------------------------------------------------------+
bool CollectExposureCurrencies(string &currencies[])
  {
//--- Start each collection with an empty exposure set
   ArrayResize(currencies, 0);

   int totalPositions = PositionsTotal();

//--- No open positions means there is currently no news exposure
   if(totalPositions == 0)
      return(true);

//--- Inspect every currently open account position
   for(int i = 0; i < totalPositions; i++)
     {
      ResetLastError();

      string symbol = PositionGetSymbol(i);

      if(symbol == "")
        {
         Print("Prop Firm Guard: Could not retrieve position symbol at index ",
               i,
               ". Error: ",
               GetLastError());

         return(false);
        }

      if(!AddPositionCurrencies(symbol, currencies))
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Build monitored currency list                                    |
//+------------------------------------------------------------------+
string BuildCurrencyList(const string &currencies[])
  {
   string result = "";
   int count = ArraySize(currencies);

//--- Append each currency using a comma-separated format
   for(int i = 0; i < count; i++)
     {
      if(i > 0)
         result += ", ";

      result += currencies[i];
     }

   return(result);
  }

//+------------------------------------------------------------------+
//| Find next news event for currency                                |
//+------------------------------------------------------------------+
bool FindNextNewsForCurrency(const string       currency,
                             const datetime     timeFrom,
                             const datetime     timeTo,
                             MqlCalendarValue  &bestValue,
                             MqlCalendarEvent  &bestEvent)
  {
   MqlCalendarValue values[];

   ResetLastError();

//--- Request calendar values for the specified currency and time range
   int valueCount = CalendarValueHistory(values,
                                         timeFrom,
                                         timeTo,
                                         NULL,
                                         currency);

   if(valueCount < 0)
     {
      Print("Prop Firm Guard: Could not retrieve calendar values for ",
            currency,
            ". Error: ",
            GetLastError());

      return(false);
     }

   bool eventFound = false;
   datetime earliestTime = 0;

//--- Inspect the calendar values returned for this currency
   for(int i = 0; i < valueCount; i++)
     {
      MqlCalendarEvent event;

      ResetLastError();

      if(!CalendarEventById(values[i].event_id,
                            event))
        {
         Print("Prop Firm Guard: Could not retrieve calendar event ",
               values[i].event_id,
               ". Error: ",
               GetLastError());

         continue;
        }

      //--- Reject events below the configured minimum importance
      if(event.importance < InpNewsImportance)
         continue;

      //--- Require a calendar event with an exact release time
      if(event.time_mode != CALENDAR_TIMEMODE_DATETIME)
         continue;

      //--- Keep the earliest qualifying event in the search interval
      if(!eventFound ||
         values[i].time < earliestTime)
        {
         bestValue = values[i];
         bestEvent = event;
         earliestTime = values[i].time;
         eventFound = true;
        }
     }

   return(eventFound);
  }

//+------------------------------------------------------------------+
//| Update news state                                                |
//+------------------------------------------------------------------+
void UpdateNewsState()
  {
//--- Clear the previous exposure and event state
   InitializeNewsState();

//--- Stop immediately when economic-news monitoring is disabled
   if(!InpEnableNewsFilter)
     {
      g_newsState.status = NEWS_DISABLED;

      return;
     }

   string currencies[];

//--- Collect one unique currency set from all supported open positions
   if(!CollectExposureCurrencies(currencies))
     {
      g_newsState.status = NEWS_UNAVAILABLE;

      return;
     }

   int currencyCount = ArraySize(currencies);

//--- No supported exposure means there is nothing to search
   if(currencyCount == 0)
     {
      g_newsState.hasExposure = false;
      g_newsState.monitoredCurrencies = 0;
      g_newsState.currencyList = "";
      g_newsState.status = NEWS_NO_EXPOSURE;

      return;
     }

//--- Store the current account-exposure summary
   g_newsState.hasExposure = true;
   g_newsState.monitoredCurrencies = currencyCount;
   g_newsState.currencyList = BuildCurrencyList(currencies);

//--- Use trade-server time for calendar and restriction calculations
   datetime currentTime = TimeTradeServer();

   datetime searchFrom =
      currentTime -
      InpMinutesAfterNews * 60;

   datetime searchTo =
      currentTime +
      24 * 60 * 60;

   bool foundAny = false;

   ulong selectedEventId = 0;
   string selectedEventName = "";
   string selectedCurrency = "";
   ENUM_CALENDAR_EVENT_IMPORTANCE selectedImportance =
      CALENDAR_IMPORTANCE_NONE;
   datetime selectedEventTime = 0;

//--- Search each exposed currency and retain the nearest event
   for(int i = 0; i < currencyCount; i++)
     {
      MqlCalendarValue candidateValue;
      MqlCalendarEvent candidateEvent;

      if(!FindNextNewsForCurrency(currencies[i],
                                  searchFrom,
                                  searchTo,
                                  candidateValue,
                                  candidateEvent))
         continue;

      if(!foundAny ||
         candidateValue.time < selectedEventTime)
        {
         selectedEventId = candidateEvent.id;
         selectedEventName = candidateEvent.name;
         selectedCurrency = currencies[i];
         selectedImportance = candidateEvent.importance;
         selectedEventTime = candidateValue.time;
         foundAny = true;
        }
     }

//--- Report an exposed account with no qualifying event
   if(!foundAny)
     {
      g_newsState.status = NEWS_NO_EVENT;

      return;
     }

//--- Store the nearest qualifying event across all exposed currencies
   g_newsState.eventFound = true;
   g_newsState.eventCurrency = selectedCurrency;
   g_newsState.eventId = selectedEventId;
   g_newsState.eventName = selectedEventName;
   g_newsState.importance = selectedImportance;
   g_newsState.eventTime = selectedEventTime;

//--- Calculate the signed distance from the current server time
   g_newsState.secondsToEvent =
      (long)(g_newsState.eventTime - currentTime);

//--- Build the configured restriction interval
   g_newsState.restrictionStart =
      g_newsState.eventTime -
      InpMinutesBeforeNews * 60;

   g_newsState.restrictionEnd =
      g_newsState.eventTime +
      InpMinutesAfterNews * 60;

//--- Determine whether the current time is inside that interval
   g_newsState.restrictedWindow =
      (currentTime >= g_newsState.restrictionStart &&
       currentTime <= g_newsState.restrictionEnd);

   if(g_newsState.restrictedWindow)
      g_newsState.status = NEWS_RESTRICTED;
   else
      g_newsState.status = NEWS_SAFE;
  }

//+------------------------------------------------------------------+
//| Format news countdown                                            |
//+------------------------------------------------------------------+
string FormatNewsCountdown(const long secondsToEvent)
  {
   long absoluteSeconds = secondsToEvent;

//--- Convert the signed value into a duration for formatting
   if(absoluteSeconds < 0)
      absoluteSeconds = -absoluteSeconds;

   int hours = (int)(absoluteSeconds / 3600);
   int minutes = (int)((absoluteSeconds % 3600) / 60);
   int seconds = (int)(absoluteSeconds % 60);

   string formatted =
      StringFormat("%02d:%02d:%02d",
                   hours,
                   minutes,
                   seconds);

//--- Prefix post-event elapsed time (secondsToEvent < 0) with a plus sign
   if(secondsToEvent >= 0)
      return(formatted);

   return("+" + formatted);
  }

//+------------------------------------------------------------------+
//| Get trading date                                                 |
//+------------------------------------------------------------------+
string GetTradingDate()
  {
//--- Build the session date from trading-server time
   datetime serverTime = TimeCurrent();

   return(TimeToString(serverTime, TIME_DATE));
  }

//+------------------------------------------------------------------+
//| Open database                                                    |
//+------------------------------------------------------------------+
bool OpenDatabase()
  {
//--- Open or create the SQLite database
   ResetLastError();

   g_database = DatabaseOpen(g_databaseName,
                             DATABASE_OPEN_READWRITE |
                             DATABASE_OPEN_CREATE);

   if(g_database == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not open database ",
            g_databaseName,
            ". Error: ",
            GetLastError());

      return(false);
     }

   Print("Prop Firm Guard: Database opened successfully: ",
         g_databaseName);

   return(true);
  }

//+------------------------------------------------------------------+
//| Close database                                                   |
//+------------------------------------------------------------------+
void CloseDatabase()
  {
//--- Ignore the request when no database connection is active
   if(g_database == INVALID_HANDLE)
      return;

//--- Close the active SQLite connection
   ResetLastError();

   DatabaseClose(g_database);

   int errorCode = GetLastError();

   if(errorCode != 0)
     {
      Print("Prop Firm Guard: Database close reported error: ",
            errorCode);
     }
   else
     {
      Print("Prop Firm Guard: Database closed successfully.");
     }

//--- Clear the stored database handle
   g_database = INVALID_HANDLE;
  }

//+------------------------------------------------------------------+
//| Check whether database column exists                             |
//+------------------------------------------------------------------+
bool DatabaseColumnExists(const string tableName,
                          const string columnName)
  {
//--- Inspect the current table schema
   string sql = "PRAGMA table_info(" + tableName + ");";

   ResetLastError();

   int request = DatabasePrepare(g_database,
                                 sql);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not inspect table ",
            tableName,
            ". Error: ",
            GetLastError());

      return(false);
     }

   bool columnFound = false;

//--- Search the returned schema rows for the requested column
   while(true)
     {
      ResetLastError();

      if(!DatabaseRead(request))
        {
         int errorCode = GetLastError();

         if(errorCode != ERR_DATABASE_NO_MORE_DATA)
           {
            Print("Prop Firm Guard: Could not read schema for ",
                  tableName,
                  ". Error: ",
                  errorCode);
           }

         break;
        }

      string currentColumn;

      //--- PRAGMA table_info returns the column name at index 1
      if(!DatabaseColumnText(request,
                             1,
                             currentColumn))
        {
         Print("Prop Firm Guard: Could not read database column name. Error: ",
               GetLastError());

         break;
        }

      if(currentColumn == columnName)
        {
         columnFound = true;

         break;
        }
     }

//--- Release the schema request
   FinalizeDatabaseRequest(request);

   return(columnFound);
  }

//+------------------------------------------------------------------+
//| Ensure database column exists                                    |
//+------------------------------------------------------------------+
bool EnsureDatabaseColumn(const string tableName,
                          const string columnName,
                          const string columnDefinition)
  {
//--- Leave an existing column unchanged
   if(DatabaseColumnExists(tableName,
                           columnName))
      return(true);

//--- Add the missing column
   string sql =
      "ALTER TABLE " +
      tableName +
      " ADD COLUMN " +
      columnName +
      " " +
      columnDefinition +
      ";";

   ResetLastError();

   if(!DatabaseExecute(g_database,
                       sql))
     {
      Print("Prop Firm Guard: Could not add column ",
            columnName,
            " to ",
            tableName,
            ". Error: ",
            GetLastError());

      return(false);
     }

   Print("Prop Firm Guard: Added database column ",
         tableName,
         ".",
         columnName,
         ".");

   return(true);
  }

//+------------------------------------------------------------------+
//| Ensure runtime daily-session columns exist                       |
//+------------------------------------------------------------------+
bool EnsureDailySessionRuntimeColumns()
  {
//--- Add runtime persistence columns when missing
   if(!EnsureDatabaseColumn("daily_sessions",
                            "latest_balance",
                            "REAL NOT NULL DEFAULT 0"))
      return(false);

   if(!EnsureDatabaseColumn("daily_sessions",
                            "latest_equity",
                            "REAL NOT NULL DEFAULT 0"))
      return(false);

   if(!EnsureDatabaseColumn("daily_sessions",
                            "daily_loss",
                            "REAL NOT NULL DEFAULT 0"))
      return(false);

   if(!EnsureDatabaseColumn("daily_sessions",
                            "maximum_daily_loss_reached",
                            "REAL NOT NULL DEFAULT 0"))
      return(false);

   if(!EnsureDatabaseColumn("daily_sessions",
                            "target_progress",
                            "REAL NOT NULL DEFAULT 0"))
      return(false);

   if(!EnsureDatabaseColumn("daily_sessions",
                            "session_status",
                            "TEXT NOT NULL DEFAULT 'AWAITING_CONFIRMATION'"))
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Ensure database tables exist                                     |
//+------------------------------------------------------------------+
bool EnsureDatabaseTables()
  {
//--- Define account-level settings storage
   string settingsTable =
      "CREATE TABLE IF NOT EXISTS settings ("
      "account_login INTEGER NOT NULL,"
      "account_server TEXT NOT NULL,"
      "initial_balance REAL NOT NULL,"
      "daily_drawdown_percent REAL NOT NULL,"
      "overall_drawdown_percent REAL NOT NULL,"
      "profit_target_percent REAL NOT NULL,"
      "updated_at INTEGER NOT NULL,"
      "PRIMARY KEY(account_login, account_server)"
      ");";

//--- Define persistent trading-day storage
   string dailySessionsTable =
      "CREATE TABLE IF NOT EXISTS daily_sessions ("
      "account_login INTEGER NOT NULL,"
      "account_server TEXT NOT NULL,"
      "trading_date TEXT NOT NULL,"
      "starting_balance REAL NOT NULL,"
      "starting_equity REAL NOT NULL,"
      "balance_confirmed INTEGER NOT NULL,"
      "latest_balance REAL NOT NULL DEFAULT 0,"
      "latest_equity REAL NOT NULL DEFAULT 0,"
      "daily_loss REAL NOT NULL DEFAULT 0,"
      "maximum_daily_loss_reached REAL NOT NULL DEFAULT 0,"
      "target_progress REAL NOT NULL DEFAULT 0,"
      "session_status TEXT NOT NULL DEFAULT 'AWAITING_CONFIRMATION',"
      "created_at INTEGER NOT NULL,"
      "updated_at INTEGER NOT NULL,"
      "PRIMARY KEY(account_login, account_server, trading_date)"
      ");";

//--- Ensure the account settings table exists
   ResetLastError();

   if(!DatabaseExecute(g_database,
                       settingsTable))
     {
      Print("Prop Firm Guard: Could not create settings table. Error: ",
            GetLastError());

      return(false);
     }

//--- Ensure the daily-session table exists
   ResetLastError();

   if(!DatabaseExecute(g_database,
                       dailySessionsTable))
     {
      Print("Prop Firm Guard: Could not create daily_sessions table. Error: ",
            GetLastError());

      return(false);
     }

//--- Extend an existing daily-session table when required
   if(!EnsureDailySessionRuntimeColumns())
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Check for new trading day                                        |
//+------------------------------------------------------------------+
void CheckForNewTradingDay()
  {
//--- Read the current server-based trading date
   string currentDate = GetTradingDate();

//--- Keep the active session when it already belongs to today
   if(g_hasDailySession &&
      g_dailySession.tradingDate == currentDate)
      return;

   Print("Prop Firm Guard: New trading day detected: ",
         currentDate);

//--- Restore or create the session for the new trading date
   if(!InitializeDailySession())
     {
      Print("Prop Firm Guard: Could not initialize the new daily session.");

      return;
     }

//--- Rebuild the confirmation controls for the newly loaded session
   DeleteDailySessionControls();

   if(!CreateDailySessionControls())
     {
      Print("Prop Firm Guard: Could not create daily session controls.");
     }
  }

//+------------------------------------------------------------------+
//| Finalize database request                                        |
//+------------------------------------------------------------------+
void FinalizeDatabaseRequest(const int request)
  {
//--- Ignore invalid database requests
   if(request == INVALID_HANDLE)
      return;

//--- Release the prepared database request
   ResetLastError();

   DatabaseFinalize(request);

   int errorCode = GetLastError();

   if(errorCode != 0)
     {
      Print("Prop Firm Guard: Could not finalize database request. Error: ",
            errorCode);
     }
  }

//+------------------------------------------------------------------+
//| Execute prepared database statement                              |
//+------------------------------------------------------------------+
bool ExecuteDatabaseRequest(const int request,
                            const string operation)
  {
//--- Execute the prepared database statement
   ResetLastError();

   bool result = DatabaseRead(request);

   int errorCode = GetLastError();

//--- Accept normal completion when no result row is returned
   bool success =
      (result || errorCode == ERR_DATABASE_NO_MORE_DATA);

   if(!success)
     {
      Print("Prop Firm Guard: Database error while ",
            operation,
            ". Error: ",
            errorCode);
     }

//--- Release the request after execution
   FinalizeDatabaseRequest(request);

   return(success);
  }

//+------------------------------------------------------------------+
//| Save account settings                                            |
//+------------------------------------------------------------------+
bool SaveAccountSettings()
  {
//--- Prepare the account-settings write statement
   string sql =
      "INSERT OR REPLACE INTO settings ("
      "account_login,"
      "account_server,"
      "initial_balance,"
      "daily_drawdown_percent,"
      "overall_drawdown_percent,"
      "profit_target_percent,"
      "updated_at"
      ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);";

   int request = DatabasePrepare(g_database, sql);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not prepare settings save request. Error: ",
            GetLastError());

      return(false);
     }

//--- Bind the current account settings to the prepared statement
   if(!DatabaseBind(request, 0, g_accountSettings.accountLogin) ||
      !DatabaseBind(request, 1, g_accountSettings.accountServer) ||
      !DatabaseBind(request, 2, g_accountSettings.initialBalance) ||
      !DatabaseBind(request, 3, g_accountSettings.dailyDrawdownPercent) ||
      !DatabaseBind(request, 4, g_accountSettings.overallDrawdownPercent) ||
      !DatabaseBind(request, 5, g_accountSettings.profitTargetPercent) ||
      !DatabaseBind(request, 6, g_accountSettings.updatedAt))
     {
      Print("Prop Firm Guard: Could not bind settings values. Error: ",
            GetLastError());

      FinalizeDatabaseRequest(request);
      return(false);
     }

//--- Execute and finalize the prepared write request
   if(!ExecuteDatabaseRequest(request, "saving account settings"))
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Load account settings                                            |
//+------------------------------------------------------------------+
bool LoadAccountSettings()
  {
//--- Build the current account/server lookup
   string accountServer = AccountInfoString(ACCOUNT_SERVER);

   string sql =
      "SELECT "
      "account_login,"
      "account_server,"
      "initial_balance,"
      "daily_drawdown_percent,"
      "overall_drawdown_percent,"
      "profit_target_percent,"
      "updated_at "
      "FROM settings "
      "WHERE account_login = ?1 AND account_server = ?2;";

   int request = DatabasePrepare(g_database, sql);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not prepare settings load request. Error: ",
            GetLastError());

      return(false);
     }

//--- Bind the current account identity
   if(!DatabaseBind(request, 0, g_accountState.login) ||
      !DatabaseBind(request, 1, accountServer))
     {
      Print("Prop Firm Guard: Could not bind settings search values. Error: ",
            GetLastError());

      FinalizeDatabaseRequest(request);
      return(false);
     }

//--- Read the matching settings record
   ResetLastError();

   if(!DatabaseRead(request))
     {
      int errorCode = GetLastError();

      FinalizeDatabaseRequest(request);

      //--- No row means this account/server pair has not been saved yet
      if(errorCode == ERR_DATABASE_NO_MORE_DATA)
         return(false);

      Print("Prop Firm Guard: Could not read account settings. Error: ",
            errorCode);

      return(false);
     }

//--- Read and validate the stored column values
   long   accountLogin;
   string storedServer;
   double initialBalance;
   double dailyDrawdown;
   double overallDrawdown;
   double profitTarget;
   long   updatedAt;

   if(!DatabaseColumnLong(request, 0, accountLogin) ||
      !DatabaseColumnText(request, 1, storedServer) ||
      !DatabaseColumnDouble(request, 2, initialBalance) ||
      !DatabaseColumnDouble(request, 3, dailyDrawdown) ||
      !DatabaseColumnDouble(request, 4, overallDrawdown) ||
      !DatabaseColumnDouble(request, 5, profitTarget) ||
      !DatabaseColumnLong(request, 6, updatedAt))
     {
      Print("Prop Firm Guard: Could not read stored settings columns. Error: ",
            GetLastError());

      FinalizeDatabaseRequest(request);
      return(false);
     }

//--- Restore the stored values into the account settings structure
   g_accountSettings.accountLogin           = accountLogin;
   g_accountSettings.accountServer          = storedServer;
   g_accountSettings.initialBalance         = initialBalance;
   g_accountSettings.dailyDrawdownPercent   = dailyDrawdown;
   g_accountSettings.overallDrawdownPercent = overallDrawdown;
   g_accountSettings.profitTargetPercent    = profitTarget;
   g_accountSettings.updatedAt              = (datetime)updatedAt;

//--- Release the completed read request
   FinalizeDatabaseRequest(request);

   return(true);
  }

//+------------------------------------------------------------------+
//| Initialize daily session                                         |
//+------------------------------------------------------------------+
bool InitializeDailySession()
  {
//--- Identify the current trading day
   string tradingDate = GetTradingDate();

//--- Restore today's session when it already exists
   if(DailySessionExists(tradingDate))
     {
      if(!LoadDailySession())
         return(false);

      g_hasDailySession = true;

      Print("Prop Firm Guard: Daily session restored for ",
            tradingDate,
            ".");

      return(true);
     }

//--- Create a new unconfirmed session for the current trading day
   g_dailySession.accountLogin = g_accountState.login;
   g_dailySession.accountServer = AccountInfoString(ACCOUNT_SERVER);
   g_dailySession.tradingDate = tradingDate;
   g_dailySession.startingBalance = 0.0;
   g_dailySession.startingEquity = 0.0;
   g_dailySession.balanceConfirmed = false;
   g_dailySession.latestBalance = g_accountState.balance;
   g_dailySession.latestEquity = g_accountState.equity;
   g_dailySession.dailyLoss = 0.0;
   g_dailySession.maximumDailyLossReached = 0.0;
   g_dailySession.targetProgress = 0.0;
   g_dailySession.sessionStatus = "AWAITING_CONFIRMATION";
   g_dailySession.createdAt = TimeCurrent();
   g_dailySession.updatedAt = TimeCurrent();

//--- Persist the new daily-session record
   if(!SaveDailySession())
      return(false);

   g_hasDailySession = true;

   Print("Prop Firm Guard: New daily session created for ",
         tradingDate,
         ".");

   return(true);
  }

//+------------------------------------------------------------------+
//| Initialize account settings                                      |
//+------------------------------------------------------------------+
bool InitializeAccountSettings()
  {
//--- Check whether this account/server pair already has stored settings
   bool settingsFound = LoadAccountSettings();

//--- Associate the settings with the current trading account
   g_accountSettings.accountLogin = g_accountState.login;
   g_accountSettings.accountServer = AccountInfoString(ACCOUNT_SERVER);

//--- Synchronize persistence with the current Inputs values
   g_accountSettings.initialBalance = InpInitialAccountBalance;
   g_accountSettings.dailyDrawdownPercent = InpDailyDrawdownPercent;
   g_accountSettings.overallDrawdownPercent = InpOverallDrawdownPercent;
   g_accountSettings.profitTargetPercent = InpProfitTargetPercent;
   g_accountSettings.updatedAt = TimeCurrent();

//--- Save the synchronized configuration
   if(!SaveAccountSettings())
      return(false);

//--- Report whether the record was created or synchronized
   if(settingsFound)
      Print("Prop Firm Guard: Account settings restored and synchronized.");
   else
      Print("Prop Firm Guard: New account settings saved.");

   return(true);
  }

//+------------------------------------------------------------------+
//| Save daily session                                               |
//+------------------------------------------------------------------+
bool SaveDailySession()
  {
//--- Prepare the complete daily-session record
   string sql =
      "INSERT OR REPLACE INTO daily_sessions ("
      "account_login,"
      "account_server,"
      "trading_date,"
      "starting_balance,"
      "starting_equity,"
      "balance_confirmed,"
      "latest_balance,"
      "latest_equity,"
      "daily_loss,"
      "maximum_daily_loss_reached,"
      "target_progress,"
      "session_status,"
      "created_at,"
      "updated_at"
      ") VALUES ("
      "?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14"
      ");";

   ResetLastError();

   int request = DatabasePrepare(g_database,
                                 sql,
                                 g_dailySession.accountLogin,
                                 g_dailySession.accountServer,
                                 g_dailySession.tradingDate,
                                 g_dailySession.startingBalance,
                                 g_dailySession.startingEquity,
                                 g_dailySession.balanceConfirmed ? 1 : 0,
                                 g_dailySession.latestBalance,
                                 g_dailySession.latestEquity,
                                 g_dailySession.dailyLoss,
                                 g_dailySession.maximumDailyLossReached,
                                 g_dailySession.targetProgress,
                                 g_dailySession.sessionStatus,
                                 (long)g_dailySession.createdAt,
                                 (long)g_dailySession.updatedAt);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not prepare daily session save request. Error: ",
            GetLastError());

      return(false);
     }

//--- Execute and finalize the prepared write request
   return(ExecuteDatabaseRequest(request,
                                 "saving daily session"));
  }

//+------------------------------------------------------------------+
//| Load daily session                                               |
//+------------------------------------------------------------------+
bool LoadDailySession()
  {
//--- Select the session belonging to the current account and date
   string sql =
      "SELECT "
      "account_login,"
      "account_server,"
      "trading_date,"
      "starting_balance,"
      "starting_equity,"
      "balance_confirmed,"
      "latest_balance,"
      "latest_equity,"
      "daily_loss,"
      "maximum_daily_loss_reached,"
      "target_progress,"
      "session_status,"
      "created_at,"
      "updated_at "
      "FROM daily_sessions "
      "WHERE account_login=?1 "
      "AND account_server=?2 "
      "AND trading_date=?3;";

   string tradingDate = GetTradingDate();
   string accountServer = AccountInfoString(ACCOUNT_SERVER);

   ResetLastError();

   int request = DatabasePrepare(g_database,
                                 sql,
                                 g_accountState.login,
                                 accountServer,
                                 tradingDate);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not prepare daily session load request. Error: ",
            GetLastError());

      return(false);
     }

//--- Read the matching record
   ResetLastError();

   if(!DatabaseRead(request))
     {
      int errorCode = GetLastError();

      if(errorCode != ERR_DATABASE_NO_MORE_DATA)
        {
         Print("Prop Firm Guard: Could not load daily session. Error: ",
               errorCode);
        }

      FinalizeDatabaseRequest(request);

      return(false);
     }

//--- Read all stored values before updating the in-memory session
   long accountLogin;
   string loadedServer;
   string loadedDate;
   double startingBalance;
   double startingEquity;
   int balanceConfirmed;
   double latestBalance;
   double latestEquity;
   double dailyLoss;
   double maximumDailyLossReached;
   double targetProgress;
   string sessionStatus;
   long createdAt;
   long updatedAt;

   bool loaded =
      DatabaseColumnLong(request, 0, accountLogin) &&
      DatabaseColumnText(request, 1, loadedServer) &&
      DatabaseColumnText(request, 2, loadedDate) &&
      DatabaseColumnDouble(request, 3, startingBalance) &&
      DatabaseColumnDouble(request, 4, startingEquity) &&
      DatabaseColumnInteger(request, 5, balanceConfirmed) &&
      DatabaseColumnDouble(request, 6, latestBalance) &&
      DatabaseColumnDouble(request, 7, latestEquity) &&
      DatabaseColumnDouble(request, 8, dailyLoss) &&
      DatabaseColumnDouble(request, 9, maximumDailyLossReached) &&
      DatabaseColumnDouble(request, 10, targetProgress) &&
      DatabaseColumnText(request, 11, sessionStatus) &&
      DatabaseColumnLong(request, 12, createdAt) &&
      DatabaseColumnLong(request, 13, updatedAt);

   if(!loaded)
     {
      Print("Prop Firm Guard: Could not read daily session columns. Error: ",
            GetLastError());

      FinalizeDatabaseRequest(request);

      return(false);
     }

//--- Restore the complete daily-session state
   g_dailySession.accountLogin = accountLogin;
   g_dailySession.accountServer = loadedServer;
   g_dailySession.tradingDate = loadedDate;
   g_dailySession.startingBalance = startingBalance;
   g_dailySession.startingEquity = startingEquity;
   g_dailySession.balanceConfirmed = (balanceConfirmed != 0);
   g_dailySession.latestBalance = latestBalance;
   g_dailySession.latestEquity = latestEquity;
   g_dailySession.dailyLoss = dailyLoss;
   g_dailySession.maximumDailyLossReached = maximumDailyLossReached;
   g_dailySession.targetProgress = targetProgress;
   g_dailySession.sessionStatus = sessionStatus;
   g_dailySession.createdAt = (datetime)createdAt;
   g_dailySession.updatedAt = (datetime)updatedAt;

//--- Release the completed read request
   FinalizeDatabaseRequest(request);

   return(true);
  }

//+------------------------------------------------------------------+
//| Check daily session existence                                    |
//+------------------------------------------------------------------+
bool DailySessionExists(const string tradingDate)
  {
//--- Build the session identity for the requested trading date
   string accountServer = AccountInfoString(ACCOUNT_SERVER);

   string sql =
      "SELECT 1 "
      "FROM daily_sessions "
      "WHERE account_login = ?1 "
      "AND account_server = ?2 "
      "AND trading_date = ?3 "
      "LIMIT 1;";

   int request = DatabasePrepare(g_database, sql);

   if(request == INVALID_HANDLE)
     {
      Print("Prop Firm Guard: Could not prepare session existence request. Error: ",
            GetLastError());

      return(false);
     }

//--- Bind the current account, server, and requested date
   if(!DatabaseBind(request, 0, g_accountState.login) ||
      !DatabaseBind(request, 1, accountServer) ||
      !DatabaseBind(request, 2, tradingDate))
     {
      Print("Prop Firm Guard: Could not bind session existence values. Error: ",
            GetLastError());

      FinalizeDatabaseRequest(request);
      return(false);
     }

//--- Check whether one matching row exists
   ResetLastError();

   bool exists = DatabaseRead(request);

   int errorCode = GetLastError();

   FinalizeDatabaseRequest(request);

   if(!exists && errorCode != ERR_DATABASE_NO_MORE_DATA)
     {
      Print("Prop Firm Guard: Could not check daily session existence. Error: ",
            errorCode);
     }

   return(exists);
  }

//+------------------------------------------------------------------+
//| Create starting balance edit                                     |
//+------------------------------------------------------------------+
bool CreateStartingBalanceEdit(const int    x,
                               const int    y,
                               const string suggestedBalance)
  {
//--- Create the editable starting-balance field
   if(!ObjectCreate(0,
                    g_startBalanceEdit,
                    OBJ_EDIT,
                    0,
                    0,
                    0))
     {
      Print("Prop Firm Guard: Could not create starting balance field. Error: ",
            GetLastError());

      return(false);
     }

//--- Configure the field position and appearance
   if(!ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_CORNER,
                        CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_XDISTANCE,
                        x) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_YDISTANCE,
                        y) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_XSIZE,
                        120) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_YSIZE,
                        20) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_FONTSIZE,
                        9) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_COLOR,
                        clrBlack) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_BGCOLOR,
                        clrWhite) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_BORDER_COLOR,
                        clrSilver) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_ALIGN,
                        ALIGN_RIGHT) ||
      !ObjectSetInteger(0,
                        g_startBalanceEdit,
                        OBJPROP_HIDDEN,
                        true))
     {
      Print("Prop Firm Guard: Could not configure starting balance field. Error: ",
            GetLastError());

      return(false);
     }

//--- Apply the suggested balance and text properties
   if(!ObjectSetString(0,
                       g_startBalanceEdit,
                       OBJPROP_FONT,
                       "Tahoma") ||
      !ObjectSetString(0,
                       g_startBalanceEdit,
                       OBJPROP_TEXT,
                       suggestedBalance))
     {
      Print("Prop Firm Guard: Could not initialize starting balance field. Error: ",
            GetLastError());

      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Create confirm balance button                                    |
//+------------------------------------------------------------------+
bool CreateConfirmBalanceButton(const int x,
                                const int y)
  {
//--- Create the daily-balance confirmation button
   if(!ObjectCreate(0,
                    g_confirmButton,
                    OBJ_BUTTON,
                    0,
                    0,
                    0))
     {
      Print("Prop Firm Guard: Could not create confirmation button. Error: ",
            GetLastError());

      return(false);
     }

//--- Configure the button position and appearance
   if(!ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_CORNER,
                        CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_XDISTANCE,
                        x) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_YDISTANCE,
                        y) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_XSIZE,
                        100) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_YSIZE,
                        20) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_FONTSIZE,
                        9) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_COLOR,
                        clrBlack) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_BGCOLOR,
                        clrWhite) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_BORDER_COLOR,
                        clrSilver) ||
      !ObjectSetInteger(0,
                        g_confirmButton,
                        OBJPROP_HIDDEN,
                        true))
     {
      Print("Prop Firm Guard: Could not configure confirmation button. Error: ",
            GetLastError());

      return(false);
     }

//--- Apply the button text and font
   if(!ObjectSetString(0,
                       g_confirmButton,
                       OBJPROP_FONT,
                       "Tahoma") ||
      !ObjectSetString(0,
                       g_confirmButton,
                       OBJPROP_TEXT,
                       "Confirm"))
     {
      Print("Prop Firm Guard: Could not initialize confirmation button. Error: ",
            GetLastError());

      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Create daily session controls                                    |
//+------------------------------------------------------------------+
bool CreateDailySessionControls()
  {
//--- Skip the controls when today's balance is already confirmed
   if(g_dailySession.balanceConfirmed)
      return(true);

   int controlX = InpDashboardX + 18;
   int controlY = InpDashboardY + 120;

//--- Suggest the current balance without confirming it
   string suggestedBalance =
      DoubleToString(g_accountState.balance, 2);

//--- Create the editable starting-balance field
   if(!CreateStartingBalanceEdit(controlX,
                                 controlY,
                                 suggestedBalance))
      return(false);

//--- Create the confirmation button beside the edit field
   if(!CreateConfirmBalanceButton(controlX + 130,
                                  controlY))
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Delete daily session controls                                    |
//+------------------------------------------------------------------+
void DeleteDailySessionControls()
  {
//--- Remove the starting-balance field when present
   if(ObjectFind(0, g_startBalanceEdit) >= 0)
     {
      if(!ObjectDelete(0, g_startBalanceEdit))
        {
         Print("Prop Firm Guard: Could not delete starting balance field. Error: ",
               GetLastError());
        }
     }

//--- Remove the confirmation button when present
   if(ObjectFind(0, g_confirmButton) >= 0)
     {
      if(!ObjectDelete(0, g_confirmButton))
        {
         Print("Prop Firm Guard: Could not delete confirmation button. Error: ",
               GetLastError());
        }
     }

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Confirm daily starting balance                                   |
//+------------------------------------------------------------------+
bool ConfirmDailyStartingBalance()
  {
//--- Keep an existing confirmed baseline unchanged
   if(g_dailySession.balanceConfirmed)
     {
      Print("Prop Firm Guard: Today's starting balance is already confirmed.");

      return(true);
     }

   string balanceText;

   ResetLastError();

//--- Read the amount entered in the dashboard field
   if(!ObjectGetString(0,
                       g_startBalanceEdit,
                       OBJPROP_TEXT,
                       0,
                       balanceText))
     {
      Print("Prop Firm Guard: Could not read starting balance field. Error: ",
            GetLastError());

      return(false);
     }

   double startingBalance = StringToDouble(balanceText);

//--- Validate the entered starting balance
   if(startingBalance <= 0.0)
     {
      Alert("Prop Firm Guard: Enter a valid starting balance greater than zero.");

      return(false);
     }

//--- Store the confirmed daily reference
   g_dailySession.startingBalance  = startingBalance;
   g_dailySession.startingEquity   = g_accountState.equity;
   g_dailySession.balanceConfirmed = true;
   g_dailySession.updatedAt        = TimeCurrent();

//--- Persist the confirmed session immediately
   if(!SaveDailySession())
     {
      Print("Prop Firm Guard: Could not save confirmed daily session.");

      //--- Keep the in memory state consistent with the database result
      g_dailySession.balanceConfirmed = false;

      return(false);
     }

   Print("Prop Firm Guard: Daily starting balance confirmed at ",
         DoubleToString(g_dailySession.startingBalance, 2),
         " for ",
         g_dailySession.tradingDate,
         ".");

//--- Remove the confirmation controls after a successful save
   DeleteDailySessionControls();

//--- Refresh the dashboard with the confirmed session state
   UpdateDashboard();

   return(true);
  }

//+------------------------------------------------------------------+
//| Convert compliance status to text                                |
//+------------------------------------------------------------------+
string ComplianceStatusToString(const ENUM_COMPLIANCE_STATUS status)
  {
   switch(status)
     {
      case COMPLIANCE_WARNING:
         return("WARNING");

      case COMPLIANCE_CRITICAL:
         return("CRITICAL");

      case COMPLIANCE_BREACHED:
         return("BREACHED");

      case COMPLIANCE_SAFE:
      default:
         return("SAFE");
     }
  }

//+------------------------------------------------------------------+
//| Convert target status to text                                    |
//+------------------------------------------------------------------+
string TargetStatusToString(const ENUM_TARGET_STATUS status)
  {
   switch(status)
     {
      case TARGET_NEARING:
         return("NEARING TARGET");

      case TARGET_REACHED:
         return("TARGET REACHED");

      case TARGET_IN_PROGRESS:
      default:
         return("IN PROGRESS");
     }
  }

//+------------------------------------------------------------------+
//| Convert news holding status to text                              |
//+------------------------------------------------------------------+
string NewsHoldingStatusToString(const ENUM_NEWS_HOLDING_STATUS status)
  {
   switch(status)
     {
      case NEWS_HOLDING_ALLOWED:
         return("HOLDING ALLOWED");

      case NEWS_HOLDING_WARNING:
         return("EVENT APPROACHING");

      case NEWS_HOLDING_PROTECTION:
         return("PROTECTION REQUIRED");

      case NEWS_HOLDING_CLEAR:
      default:
         return("CLEAR");
     }
  }

//+------------------------------------------------------------------+
//| Get overall guard status                                         |
//+------------------------------------------------------------------+
ENUM_GUARD_STATUS GetOverallGuardStatus()
  {
//--- Give the highest priority to any drawdown breach
   if(g_dailyDrawdown.status == COMPLIANCE_BREACHED ||
      g_overallDrawdown.status == COMPLIANCE_BREACHED)
      return(GUARD_BREACHED);

//--- Check for a critical drawdown condition
   if(g_dailyDrawdown.status == COMPLIANCE_CRITICAL ||
      g_overallDrawdown.status == COMPLIANCE_CRITICAL)
      return(GUARD_CRITICAL);

//--- Check for a warning condition
   if(g_dailyDrawdown.status == COMPLIANCE_WARNING ||
      g_overallDrawdown.status == COMPLIANCE_WARNING)
      return(GUARD_WARNING);

//--- Report target completion only when no risk condition has priority
   if(g_profitTarget.status == TARGET_REACHED)
      return(GUARD_TARGET_REACHED);

   return(GUARD_SAFE);
  }

//+------------------------------------------------------------------+
//| Convert guard status to text                                     |
//+------------------------------------------------------------------+
string GuardStatusToString(const ENUM_GUARD_STATUS status)
  {
   switch(status)
     {
      case GUARD_BREACHED:
         return("BREACHED");

      case GUARD_CRITICAL:
         return("CRITICAL");

      case GUARD_WARNING:
         return("WARNING");

      case GUARD_TARGET_REACHED:
         return("TARGET REACHED");

      case GUARD_SAFE:
      default:
         return("SAFE");
     }
  }

//+------------------------------------------------------------------+
//| Get news trading window text                                     |
//+------------------------------------------------------------------+
string GetNewsTradingWindowText()
  {
//--- Report the configured filter state
   if(!InpEnableNewsFilter)
      return("DISABLED");

//--- A missing relevant event leaves the current window safe
   if(!g_newsState.eventFound)
      return("SAFE");

//--- Report the active restricted interval
   if(g_newsState.restrictedWindow)
      return("RESTRICTED");

   return("SAFE");
  }

//+------------------------------------------------------------------+
//| Get configured news holding rule                                 |
//+------------------------------------------------------------------+
string GetNewsHoldingRuleText()
  {
//--- Convert the configured holding rule into dashboard text
   if(InpAllowNewsHolding)
      return("ALLOWED");

   return("NOT ALLOWED");
  }

//+------------------------------------------------------------------+
//| Get guard status color                                           |
//+------------------------------------------------------------------+
color GetGuardStatusColor(const ENUM_GUARD_STATUS status)
  {
   switch(status)
     {
      case GUARD_BREACHED:
      case GUARD_CRITICAL:
         return(clrRed);

      case GUARD_WARNING:
         return(clrDarkOrange);

      case GUARD_TARGET_REACHED:
         return(clrGreen);

      case GUARD_SAFE:
      default:
         return(clrGreen);
     }
  }

//+------------------------------------------------------------------+
//| Get daily session status                                         |
//+------------------------------------------------------------------+
string GetDailySessionStatus()
  {
//--- An unconfirmed starting balance keeps the session in setup
   if(!g_dailySession.balanceConfirmed)
      return("AWAITING_CONFIRMATION");

//--- A drawdown breach has the highest session priority
   if(g_dailyDrawdown.status == COMPLIANCE_BREACHED ||
      g_overallDrawdown.status == COMPLIANCE_BREACHED)
      return("BREACHED");

//--- Record completion when the profit target has been reached
   if(g_profitTarget.status == TARGET_REACHED)
      return("TARGET_REACHED");

//--- Preserve the highest active drawdown warning level
   if(g_dailyDrawdown.status == COMPLIANCE_CRITICAL ||
      g_overallDrawdown.status == COMPLIANCE_CRITICAL)
      return("CRITICAL");

   if(g_dailyDrawdown.status == COMPLIANCE_WARNING ||
      g_overallDrawdown.status == COMPLIANCE_WARNING)
      return("WARNING");

   return("ACTIVE");
  }

//+------------------------------------------------------------------+
//| Update runtime daily session state                               |
//+------------------------------------------------------------------+
bool UpdateDailySessionRuntimeState()
  {
//--- Runtime persistence requires an active daily session
   if(!g_hasDailySession)
      return(false);

//--- Copy the latest account and target values into the session
   g_dailySession.latestBalance = g_accountState.balance;
   g_dailySession.latestEquity = g_accountState.equity;
   g_dailySession.targetProgress = g_profitTarget.progressPercent;
   g_dailySession.sessionStatus = GetDailySessionStatus();
   g_dailySession.updatedAt = TimeCurrent();

//--- Update daily loss only after the session baseline is confirmed
   if(g_dailySession.balanceConfirmed)
     {
      g_dailySession.dailyLoss = g_dailyDrawdown.currentDailyLoss;

      //--- Preserve the greatest daily loss observed during this trading day
      if(g_dailyDrawdown.currentDailyLoss >
         g_dailySession.maximumDailyLossReached)
        {
         g_dailySession.maximumDailyLossReached =
            g_dailyDrawdown.currentDailyLoss;
        }
     }
   else
     {
      g_dailySession.dailyLoss = 0.0;
     }

//--- Save the synchronized runtime snapshot
   return(SaveDailySession());
  }

//+------------------------------------------------------------------+
//| Update runtime database when due                                 |
//+------------------------------------------------------------------+
void UpdateRuntimeDatabase()
  {
//--- Read the current terminal time
   datetime currentTime = TimeCurrent();

//--- Limit runtime session writes to one update every 10 seconds
   if(g_lastRuntimeDatabaseUpdate != 0 &&
      currentTime - g_lastRuntimeDatabaseUpdate < 10)
      return;

//--- Save the latest runtime snapshot and remember a successful update
   if(UpdateDailySessionRuntimeState())
      g_lastRuntimeDatabaseUpdate = currentTime;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Validate the timer interval
   if(InpTimerSeconds < 1)
     {
      Print("Prop Firm Guard: Timer interval must be at least 1 second.");

      return(INIT_PARAMETERS_INCORRECT);
     }

//--- Validate the configured compliance inputs
   if(!ValidateComplianceInputs())
      return(INIT_PARAMETERS_INCORRECT);

//--- Prepare the chart before creating dashboard objects
   if(!ConfigureChartAppearance())
     {
      Print("Prop Firm Guard: Could not configure chart appearance.");

      return(INIT_FAILED);
     }

//--- Use synchronous trade execution for protection actions
   g_trade.SetAsyncMode(false);

//--- Read the current account state
   UpdateAccountState();

//--- Open the SQLite database
   if(!OpenDatabase())
     {
      Print("Prop Firm Guard: Database initialization failed.");

      return(INIT_FAILED);
     }

//--- Ensure the required database tables exist
   if(!EnsureDatabaseTables())
     {
      Print("Prop Firm Guard: Could not initialize database tables.");

      CloseDatabase();

      return(INIT_FAILED);
     }

//--- Restore account specific settings
   if(!InitializeAccountSettings())
     {
      Print("Prop Firm Guard: Could not initialize account settings.");

      CloseDatabase();

      return(INIT_FAILED);
     }

//--- Restore or create the current daily session
   if(!InitializeDailySession())
     {
      Print("Prop Firm Guard: Could not initialize daily session.");

      CloseDatabase();

      return(INIT_FAILED);
     }

//--- Calculate the initial financial compliance state
   CalculateDailyDrawdown();
   CalculateOverallDrawdown();
   CalculateProfitTarget();

//--- Calculate the initial Economic Calendar state
   UpdateNewsState();
   UpdateNewsPositionMatches();

//--- Establish the initial alert baseline
   InitializeAlertState();

//--- Create the complete monitoring dashboard
   if(!CreateDashboard())
     {
      Print("Prop Firm Guard: Failed to create the dashboard.");

      CloseDatabase();

      return(INIT_FAILED);
     }

//--- Populate the dashboard from the restored monitoring state
   UpdateDashboard();

//--- Start periodic monitoring
   if(!EventSetTimer(InpTimerSeconds))
     {
      Print("Prop Firm Guard: Failed to start the timer. Error: ",
            GetLastError());

      DeleteDashboard();
      CloseDatabase();

      return(INIT_FAILED);
     }

   Print("Prop Firm Guard initialized successfully.");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Stop periodic monitoring
   EventKillTimer();

//--- Remove all chart objects owned by Prop Firm Guard
   DeleteDashboard();

//--- Close the SQLite database
   CloseDatabase();

   Print("Prop Firm Guard removed. Deinitialization reason: ",
         reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
//--- Refresh the current account state
   UpdateAccountState();

//--- Maintain the current trading day session
   CheckForNewTradingDay();

//--- Recalculate the financial compliance state
   CalculateDailyDrawdown();
   CalculateOverallDrawdown();
   CalculateProfitTarget();

//--- Refresh Economic Calendar exposure and position classification
   UpdateNewsState();
   UpdateNewsPositionMatches();

//--- Process alert transitions and configured protection
   ManageAlerts();
   ManageProtectionActions();

//--- Refresh financial values after any protection action
   UpdateAccountState();
   CalculateDailyDrawdown();
   CalculateOverallDrawdown();
   CalculateProfitTarget();

//--- Persist the latest daily session snapshot when due
   UpdateRuntimeDatabase();

//--- Present the resulting monitoring state
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Chart event function                                             |
//+------------------------------------------------------------------+
void OnChartEvent(const int    id,
                  const long   &lparam,
                  const double &dparam,
                  const string &sparam)
  {
//--- Process chart-object clicks only
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

//--- Confirm the entered balance when the confirmation button is clicked
   if(sparam == g_confirmButton)
     {
      if(!ConfirmDailyStartingBalance())
         Print("Prop Firm Guard: Starting balance confirmation failed.");
     }
  }

//+------------------------------------------------------------------+
//| Check successful position-close return code                      |
//+------------------------------------------------------------------+
bool IsSuccessfulCloseRetcode(const uint retcode)
  {
//--- Accept only return codes that confirm complete closure
   if(retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_POSITION_CLOSED)
      return(true);

   return(false);
  }

//+------------------------------------------------------------------+
//| Close position by ticket                                         |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(const ulong ticket,
                           const string reason)
  {
//--- Confirm that the position still exists
   ResetLastError();

   if(!PositionSelectByTicket(ticket))
     {
      int errorCode = GetLastError();

      Print("Prop Firm Guard: Position ",
            ticket,
            " is no longer available. Error: ",
            errorCode);

      return(true);
     }

   string symbol;

//--- Read the symbol associated with the selected ticket
   if(!PositionGetString(POSITION_SYMBOL,
                         symbol))
     {
      Print("Prop Firm Guard: Could not read symbol for position ",
            ticket,
            ". Error: ",
            GetLastError());

      return(false);
     }

//--- Use the filling policy supported by this symbol
   if(!g_trade.SetTypeFillingBySymbol(symbol))
     {
      Print("Prop Firm Guard: Could not determine filling policy for ",
            symbol,
            ".");

      return(false);
     }

//--- Submit the close request
   ResetLastError();

   bool requestAccepted = g_trade.PositionClose(ticket);

   uint retcode = g_trade.ResultRetcode();
   string retcodeDescription = g_trade.ResultRetcodeDescription();

   if(!requestAccepted)
     {
      Print("Prop Firm Guard: Close request failed for ticket ",
            ticket,
            " [",
            symbol,
            "]. Reason: ",
            reason,
            ". Retcode: ",
            retcode,
            " - ",
            retcodeDescription,
            ". Runtime error: ",
            GetLastError());

      return(false);
     }

//--- Require explicit trade-server confirmation of complete closure
   if(!IsSuccessfulCloseRetcode(retcode))
     {
      Print("Prop Firm Guard: Trade server did not confirm complete closure of ticket ",
            ticket,
            " [",
            symbol,
            "]. Reason: ",
            reason,
            ". Retcode: ",
            retcode,
            " - ",
            retcodeDescription);

      return(false);
     }

//--- Verify that the position no longer exists
   ResetLastError();

   if(PositionSelectByTicket(ticket))
     {
      Print("Prop Firm Guard: Position ",
            ticket,
            " [",
            symbol,
            "] still exists after close request.");

      return(false);
     }

   Print("Prop Firm Guard: Position ",
         ticket,
         " [",
         symbol,
         "] closed successfully. Reason: ",
         reason,
         ".");

   return(true);
  }

//+------------------------------------------------------------------+
//| Close all open positions                                         |
//+------------------------------------------------------------------+
bool CloseAllPositions(const string reason)
  {
   int totalPositions = PositionsTotal();

   if(totalPositions == 0)
      return(true);

   ulong tickets[];

//--- Allocate storage for the current position set
   if(ArrayResize(tickets, totalPositions) != totalPositions)
     {
      Print("Prop Firm Guard: Could not allocate position ticket array.");

      return(false);
     }

   int ticketCount = 0;

//--- Capture every open position ticket
   for(int i = 0; i < totalPositions; i++)
     {
      ResetLastError();

      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
        {
         Print("Prop Firm Guard: Could not retrieve position ticket at index ",
               i,
               ". Error: ",
               GetLastError());

         continue;
        }

      tickets[ticketCount] = ticket;
      ticketCount++;
     }

   bool allClosed = true;

//--- Close positions from the stable ticket list
   for(int i = 0; i < ticketCount; i++)
     {
      if(!ClosePositionByTicket(tickets[i],
                                reason))
         allClosed = false;
     }

   return(allClosed);
  }

//+------------------------------------------------------------------+
//| Close news-affected positions                                    |
//+------------------------------------------------------------------+
bool CloseNewsAffectedPositions()
  {
   ulong tickets[];

   int totalMatches = ArraySize(g_newsPositionMatches);
   int ticketCount = 0;

//--- Collect only positions marked for protection
   for(int i = 0; i < totalMatches; i++)
     {
      if(!g_newsPositionMatches[i].protectionRequired)
         continue;

      int newSize = ticketCount + 1;

      if(ArrayResize(tickets, newSize) != newSize)
        {
         Print("Prop Firm Guard: Could not expand affected-position ticket array.");

         return(false);
        }

      tickets[ticketCount] = g_newsPositionMatches[i].ticket;
      ticketCount++;
     }

   if(ticketCount == 0)
      return(true);

   bool allClosed = true;

   string reason =
      "News restriction: " +
      g_newsState.eventCurrency +
      " " +
      g_newsState.eventName;

//--- Close only the selected protection tickets
   for(int i = 0; i < ticketCount; i++)
     {
      if(!ClosePositionByTicket(tickets[i],
                                reason))
         allClosed = false;
     }

   return(allClosed);
  }

//+------------------------------------------------------------------+
//| Handle daily drawdown protection                                 |
//+------------------------------------------------------------------+
void HandleDailyDrawdownProtection()
  {
   if(!g_dailySession.balanceConfirmed)
      return;

   if(g_dailyDrawdown.status != COMPLIANCE_BREACHED)
     {
      g_dailyBreachWarned = false;

      return;
     }

   switch(InpDailyDrawdownAction)
     {
      case PROTECTION_WARN_ONLY:
         if(!g_dailyBreachWarned)
           {
            Alert("Prop Firm Guard: Daily drawdown limit breached.");
            Print("Prop Firm Guard: Daily drawdown breached. Action: WARN ONLY.");

            g_dailyBreachWarned = true;
           }

         break;

      case PROTECTION_CLOSE_AFFECTED:
      case PROTECTION_CLOSE_ALL:
         if(PositionsTotal() > 0)
           {
            if(!CloseAllPositions("Daily drawdown breach"))
               Print("Prop Firm Guard: One or more positions could not be closed after daily drawdown breach.");
           }

         break;
     }
  }

//+------------------------------------------------------------------+
//| Handle overall drawdown protection                               |
//+------------------------------------------------------------------+
void HandleOverallDrawdownProtection()
  {
   if(g_overallDrawdown.status != COMPLIANCE_BREACHED)
     {
      g_overallBreachWarned = false;

      return;
     }

   switch(InpOverallDrawdownAction)
     {
      case PROTECTION_WARN_ONLY:
         if(!g_overallBreachWarned)
           {
            Alert("Prop Firm Guard: Overall drawdown limit breached.");
            Print("Prop Firm Guard: Overall drawdown breached. Action: WARN ONLY.");

            g_overallBreachWarned = true;
           }

         break;

      case PROTECTION_CLOSE_AFFECTED:
      case PROTECTION_CLOSE_ALL:
         if(PositionsTotal() > 0)
           {
            if(!CloseAllPositions("Overall drawdown breach"))
               Print("Prop Firm Guard: One or more positions could not be closed after overall drawdown breach.");
           }

         break;
     }
  }

//+------------------------------------------------------------------+
//| Handle news protection                                           |
//+------------------------------------------------------------------+
void HandleNewsProtection()
  {
   if(g_newsState.holdingStatus != NEWS_HOLDING_PROTECTION ||
      !g_newsState.eventFound)
      return;

   switch(InpNewsRestrictionAction)
     {
      case PROTECTION_WARN_ONLY:
         if(g_lastNewsWarnedEventId != g_newsState.eventId)
           {
            Alert("Prop Firm Guard: News holding restriction active for ",
                  g_newsState.eventCurrency,
                  " ",
                  g_newsState.eventName,
                  ".");

            Print("Prop Firm Guard: News protection required. Action: WARN ONLY.");

            g_lastNewsWarnedEventId = g_newsState.eventId;
           }

         break;

      case PROTECTION_CLOSE_AFFECTED:
         if(g_newsState.protectionPositions > 0)
           {
            if(!CloseNewsAffectedPositions())
               Print("Prop Firm Guard: One or more news-affected positions could not be closed.");
           }

         break;

      case PROTECTION_CLOSE_ALL:
         if(PositionsTotal() > 0)
           {
            string reason =
               "News holding restriction: " +
               g_newsState.eventCurrency +
               " " +
               g_newsState.eventName;

            if(!CloseAllPositions(reason))
               Print("Prop Firm Guard: One or more positions could not be closed during news restriction.");
           }

         break;
     }
  }

//+------------------------------------------------------------------+
//| Manage protection actions                                        |
//+------------------------------------------------------------------+
void ManageProtectionActions()
  {
//--- Process account-wide financial protection first
   HandleDailyDrawdownProtection();
   HandleOverallDrawdownProtection();

//--- Apply news protection to any remaining exposure
   HandleNewsProtection();
  }

//+------------------------------------------------------------------+
//| Create dashboard                                                 |
//+------------------------------------------------------------------+
bool CreateDashboard()
  {
//--- Define the panel and two column positions
   string panelName = g_objectPrefix + "Panel";

   int leftX = InpDashboardX + 18;
   int rightX = InpDashboardX + 275;

//--- Create the dashboard background
   if(!ObjectCreate(0,
                    panelName,
                    OBJ_RECTANGLE_LABEL,
                    0,
                    0,
                    0))
     {
      Print("Prop Firm Guard: Could not create dashboard panel. Error: ",
            GetLastError());

      return(false);
     }

//--- Configure the dashboard panel
   if(!ObjectSetInteger(0,
                        panelName,
                        OBJPROP_CORNER,
                        CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_XDISTANCE,
                        InpDashboardX) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_YDISTANCE,
                        InpDashboardY) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_XSIZE,
                        520) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_YSIZE,
                        500) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_BGCOLOR,
                        clrWhite) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_BORDER_COLOR,
                        clrSilver) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_SELECTABLE,
                        false) ||
      !ObjectSetInteger(0,
                        panelName,
                        OBJPROP_HIDDEN,
                        true))
     {
      Print("Prop Firm Guard: Could not configure dashboard panel. Error: ",
            GetLastError());

      return(false);
     }

//--- Create the main title and overall status
   if(!CreateDashboardLabel(g_objectPrefix + "Title",
                            "PROP FIRM GUARD",
                            leftX,
                            InpDashboardY + 12,
                            11,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallStatus",
                            "",
                            rightX,
                            InpDashboardY + 14,
                            10,
                            clrBlack))
      return(false);

//--- Create the session section
   if(!CreateDashboardLabel(g_objectPrefix + "SessionHeader",
                            "SESSION",
                            leftX,
                            InpDashboardY + 42,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "TradingDate",
                            "",
                            leftX,
                            InpDashboardY + 62,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "SessionState",
                            "",
                            leftX,
                            InpDashboardY + 82,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyStart",
                            "",
                            leftX,
                            InpDashboardY + 102,
                            9,
                            clrBlack))
      return(false);

//--- Create the account section
   if(!CreateDashboardLabel(g_objectPrefix + "AccountHeader",
                            "ACCOUNT",
                            leftX,
                            InpDashboardY + 145,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "AccountLogin",
                            "",
                            leftX,
                            InpDashboardY + 165,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "Balance",
                            "",
                            leftX,
                            InpDashboardY + 185,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "Equity",
                            "",
                            leftX,
                            InpDashboardY + 205,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "FloatingPL",
                            "",
                            leftX,
                            InpDashboardY + 225,
                            9,
                            clrBlack))
      return(false);

//--- Create the daily drawdown section
   if(!CreateDashboardLabel(g_objectPrefix + "DailyDrawdownHeader",
                            "DAILY DRAWDOWN",
                            leftX,
                            InpDashboardY + 255,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyLossLimit",
                            "",
                            leftX,
                            InpDashboardY + 275,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyCurrentLoss",
                            "",
                            leftX,
                            InpDashboardY + 295,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyLimitUsage",
                            "",
                            leftX,
                            InpDashboardY + 315,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyRemaining",
                            "",
                            leftX,
                            InpDashboardY + 335,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "DailyDrawdownStatus",
                            "",
                            leftX,
                            InpDashboardY + 355,
                            9,
                            clrBlack))
      return(false);

//--- Create the overall drawdown section
   if(!CreateDashboardLabel(g_objectPrefix + "OverallDrawdownHeader",
                            "OVERALL DRAWDOWN",
                            rightX,
                            InpDashboardY + 42,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallInitialBalance",
                            "",
                            rightX,
                            InpDashboardY + 62,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallFloor",
                            "",
                            rightX,
                            InpDashboardY + 82,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallEquity",
                            "",
                            rightX,
                            InpDashboardY + 102,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallLoss",
                            "",
                            rightX,
                            InpDashboardY + 122,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallLimitUsage",
                            "",
                            rightX,
                            InpDashboardY + 142,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallRemaining",
                            "",
                            rightX,
                            InpDashboardY + 162,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "OverallDrawdownStatus",
                            "",
                            rightX,
                            InpDashboardY + 182,
                            9,
                            clrBlack))
      return(false);

//--- Create the profit target section
   if(!CreateDashboardLabel(g_objectPrefix + "ProfitTargetHeader",
                            "PROFIT TARGET",
                            rightX,
                            InpDashboardY + 220,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "TargetBalance",
                            "",
                            rightX,
                            InpDashboardY + 240,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "TargetCurrentProfit",
                            "",
                            rightX,
                            InpDashboardY + 260,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "TargetProgress",
                            "",
                            rightX,
                            InpDashboardY + 280,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "TargetRemaining",
                            "",
                            rightX,
                            InpDashboardY + 300,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "ProfitTargetStatus",
                            "",
                            rightX,
                            InpDashboardY + 320,
                            9,
                            clrBlack))
      return(false);

//--- Create the news section
   if(!CreateDashboardLabel(g_objectPrefix + "NewsHeader",
                            "NEWS",
                            rightX,
                            InpDashboardY + 350,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "NewsEvent",
                            "",
                            rightX,
                            InpDashboardY + 370,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "NewsTime",
                            "",
                            rightX,
                            InpDashboardY + 390,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "NewsCountdown",
                            "",
                            rightX,
                            InpDashboardY + 410,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "NewsRule",
                            "",
                            rightX,
                            InpDashboardY + 430,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "NewsStatus",
                            "",
                            rightX,
                            InpDashboardY + 450,
                            9,
                            clrBlack))
      return(false);

//--- Create the combined status section
   if(!CreateDashboardLabel(g_objectPrefix + "StatusHeader",
                            "STATUS",
                            leftX,
                            InpDashboardY + 390,
                            9,
                            clrDimGray))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "StatusDaily",
                            "",
                            leftX,
                            InpDashboardY + 410,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "StatusOverall",
                            "",
                            leftX,
                            InpDashboardY + 430,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "StatusTarget",
                            "",
                            leftX,
                            InpDashboardY + 450,
                            9,
                            clrBlack))
      return(false);

   if(!CreateDashboardLabel(g_objectPrefix + "StatusNews",
                            "",
                            leftX,
                            InpDashboardY + 470,
                            9,
                            clrBlack))
      return(false);

//--- Integrate the existing daily session controls
   if(!CreateDailySessionControls())
      return(false);

//--- Draw the completed static interface
   ChartRedraw();

   return(true);
  }

//+------------------------------------------------------------------+
//| Create dashboard label                                           |
//+------------------------------------------------------------------+
bool CreateDashboardLabel(const string name,
                          const string text,
                          const int    x,
                          const int    y,
                          const int    fontSize,
                          const color  textColor)
  {
//--- Create a fixed label relative to the upper left chart corner
   if(!ObjectCreate(0,
                    name,
                    OBJ_LABEL,
                    0,
                    0,
                    0))
     {
      Print("Prop Firm Guard: Could not create label ",
            name,
            ". Error: ",
            GetLastError());

      return(false);
     }

//--- Configure the label position and visual properties
   if(!ObjectSetInteger(0,
                        name,
                        OBJPROP_CORNER,
                        CORNER_LEFT_UPPER) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_XDISTANCE,
                        x) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_YDISTANCE,
                        y) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_FONTSIZE,
                        fontSize) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_COLOR,
                        textColor) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_SELECTABLE,
                        false) ||
      !ObjectSetInteger(0,
                        name,
                        OBJPROP_HIDDEN,
                        true))
     {
      Print("Prop Firm Guard: Could not configure label ",
            name,
            ". Error: ",
            GetLastError());

      return(false);
     }

//--- Set the common dashboard font and initial text
   if(!ObjectSetString(0,
                       name,
                       OBJPROP_FONT,
                       "Tahoma") ||
      !ObjectSetString(0,
                       name,
                       OBJPROP_TEXT,
                       text))
     {
      Print("Prop Firm Guard: Could not initialize label ",
            name,
            ". Error: ",
            GetLastError());

      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Update dashboard text                                            |
//+------------------------------------------------------------------+
void UpdateDashboardText(const string objectName,
                         const string text)
  {
//--- Confirm that the requested dashboard object exists
   if(ObjectFind(0,
                 objectName) < 0)
     {
      Print("Prop Firm Guard: Dashboard object not found: ",
            objectName);

      return;
     }

//--- Replace the displayed text
   if(!ObjectSetString(0,
                       objectName,
                       OBJPROP_TEXT,
                       text))
     {
      Print("Prop Firm Guard: Could not update dashboard object ",
            objectName,
            ". Error: ",
            GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Update dashboard color                                           |
//+------------------------------------------------------------------+
void UpdateDashboardColor(const string objectName,
                          const color  textColor)
  {
//--- Confirm that the requested dashboard object exists
   if(ObjectFind(0,
                 objectName) < 0)
     {
      Print("Prop Firm Guard: Dashboard object not found: ",
            objectName);

      return;
     }

//--- Apply the requested text color
   if(!ObjectSetInteger(0,
                        objectName,
                        OBJPROP_COLOR,
                        textColor))
     {
      Print("Prop Firm Guard: Could not update dashboard color for ",
            objectName,
            ". Error: ",
            GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Update dashboard                                                 |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   string sessionState;
   string dailyStart;
   string headerStatus;

   ENUM_GUARD_STATUS guardStatus = GetOverallGuardStatus();

//--- Prepare the current session and main status text
   if(g_dailySession.balanceConfirmed)
     {
      sessionState = "Session: ACTIVE";
      dailyStart =
         "Starting Balance: " +
         DoubleToString(g_dailySession.startingBalance, 2);

      headerStatus =
         "STATUS: " +
         GuardStatusToString(guardStatus);
     }
   else
     {
      sessionState = "Session: AWAITING CONFIRMATION";
      dailyStart = "Starting Balance: Not confirmed";
      headerStatus = "STATUS: SETUP REQUIRED";
     }

//--- Update session information
   UpdateDashboardText(g_objectPrefix + "TradingDate",
                       "Trading Date: " +
                       g_dailySession.tradingDate);

   UpdateDashboardText(g_objectPrefix + "SessionState",
                       sessionState);

   UpdateDashboardText(g_objectPrefix + "DailyStart",
                       dailyStart);

//--- Update account information
   UpdateDashboardText(g_objectPrefix + "AccountLogin",
                       "Account: " +
                       IntegerToString(g_accountState.login));

   UpdateDashboardText(g_objectPrefix + "Balance",
                       "Balance: " +
                       DoubleToString(g_accountState.balance, 2));

   UpdateDashboardText(g_objectPrefix + "Equity",
                       "Equity: " +
                       DoubleToString(g_accountState.equity, 2));

   UpdateDashboardText(g_objectPrefix + "FloatingPL",
                       "Floating P/L: " +
                       DoubleToString(g_accountState.floatingPL, 2));

//--- Update daily drawdown information
   if(g_dailySession.balanceConfirmed)
     {
      UpdateDashboardText(g_objectPrefix + "DailyLossLimit",
                          "Maximum Loss: " +
                          DoubleToString(g_dailyDrawdown.maximumDailyLoss, 2) +
                          " (" +
                          DoubleToString(g_accountSettings.dailyDrawdownPercent, 2) +
                          "%)");

      UpdateDashboardText(g_objectPrefix + "DailyCurrentLoss",
                          "Current Loss: " +
                          DoubleToString(g_dailyDrawdown.currentDailyLoss, 2) +
                          " (" +
                          DoubleToString(g_dailyDrawdown.drawdownPercent, 2) +
                          "%)");

      UpdateDashboardText(g_objectPrefix + "DailyLimitUsage",
                          "Limit Used: " +
                          DoubleToString(g_dailyDrawdown.limitUsagePercent, 2) +
                          "%");

      UpdateDashboardText(g_objectPrefix + "DailyRemaining",
                          "Remaining: " +
                          DoubleToString(g_dailyDrawdown.remainingAllowance, 2));

      UpdateDashboardText(g_objectPrefix + "DailyDrawdownStatus",
                          "Status: " +
                          ComplianceStatusToString(g_dailyDrawdown.status));
     }
   else
     {
      UpdateDashboardText(g_objectPrefix + "DailyLossLimit",
                          "Maximum Loss: --");

      UpdateDashboardText(g_objectPrefix + "DailyCurrentLoss",
                          "Current Loss: --");

      UpdateDashboardText(g_objectPrefix + "DailyLimitUsage",
                          "Limit Used: --");

      UpdateDashboardText(g_objectPrefix + "DailyRemaining",
                          "Remaining: --");

      UpdateDashboardText(g_objectPrefix + "DailyDrawdownStatus",
                          "Status: WAITING");
     }

//--- Update overall drawdown information
   UpdateDashboardText(g_objectPrefix + "OverallInitialBalance",
                       "Initial Balance: " +
                       DoubleToString(g_overallDrawdown.initialBalance, 2));

   UpdateDashboardText(g_objectPrefix + "OverallFloor",
                       "Equity Floor: " +
                       DoubleToString(g_overallDrawdown.overallFloor, 2));

   UpdateDashboardText(g_objectPrefix + "OverallEquity",
                       "Current Equity: " +
                       DoubleToString(g_overallDrawdown.currentEquity, 2));

   UpdateDashboardText(g_objectPrefix + "OverallLoss",
                       "Overall Loss: " +
                       DoubleToString(g_overallDrawdown.currentOverallLoss, 2));

   UpdateDashboardText(g_objectPrefix + "OverallLimitUsage",
                       "Limit Used: " +
                       DoubleToString(g_overallDrawdown.limitUsagePercent, 2) +
                       "%");

   UpdateDashboardText(g_objectPrefix + "OverallRemaining",
                       "Remaining: " +
                       DoubleToString(g_overallDrawdown.remainingAllowance, 2));

   UpdateDashboardText(g_objectPrefix + "OverallDrawdownStatus",
                       "Status: " +
                       ComplianceStatusToString(g_overallDrawdown.status));

//--- Update profit target information
   UpdateDashboardText(g_objectPrefix + "TargetBalance",
                       "Target Balance: " +
                       DoubleToString(g_profitTarget.targetBalance, 2));

   UpdateDashboardText(g_objectPrefix + "TargetCurrentProfit",
                       "Current Profit: " +
                       DoubleToString(g_profitTarget.currentProfit, 2));

   UpdateDashboardText(g_objectPrefix + "TargetProgress",
                       "Progress: " +
                       DoubleToString(g_profitTarget.progressPercent, 2) +
                       "%");

   UpdateDashboardText(g_objectPrefix + "TargetRemaining",
                       "Remaining: " +
                       DoubleToString(g_profitTarget.remainingProfit, 2));

   UpdateDashboardText(g_objectPrefix + "ProfitTargetStatus",
                       "Status: " +
                       TargetStatusToString(g_profitTarget.status));

//--- Update Economic Calendar information
   if(g_newsState.status == NEWS_DISABLED)
     {
      UpdateDashboardText(g_objectPrefix + "NewsEvent",
                          "Filter: Disabled");

      UpdateDashboardText(g_objectPrefix + "NewsTime",
                          "Trading Window: DISABLED");

      UpdateDashboardText(g_objectPrefix + "NewsCountdown",
                          "Countdown: --");

      UpdateDashboardText(g_objectPrefix + "NewsRule",
                          "Holding: --");
     }
   else
      if(g_newsState.status == NEWS_NO_EXPOSURE)
        {
         UpdateDashboardText(g_objectPrefix + "NewsEvent",
                             "No supported active exposure");

         UpdateDashboardText(g_objectPrefix + "NewsTime",
                             "Trading Window: SAFE");

         UpdateDashboardText(g_objectPrefix + "NewsCountdown",
                             "Countdown: --");

         UpdateDashboardText(g_objectPrefix + "NewsRule",
                             "Holding: " +
                             GetNewsHoldingRuleText());
        }
      else
         if(!g_newsState.eventFound)
           {
            UpdateDashboardText(g_objectPrefix + "NewsEvent",
                                "No relevant event found");

            UpdateDashboardText(g_objectPrefix + "NewsTime",
                                "Trading Window: SAFE");

            UpdateDashboardText(g_objectPrefix + "NewsCountdown",
                                "Currencies: " +
                                g_newsState.currencyList);

            UpdateDashboardText(g_objectPrefix + "NewsRule",
                                "Holding: " +
                                GetNewsHoldingRuleText());
           }
         else
           {
            UpdateDashboardText(g_objectPrefix + "NewsEvent",
                                g_newsState.eventCurrency +
                                " | " +
                                g_newsState.eventName +
                                " | " +
                                CalendarImportanceToString(g_newsState.importance));

            UpdateDashboardText(g_objectPrefix + "NewsTime",
                                "Trading Window: " +
                                GetNewsTradingWindowText());

            UpdateDashboardText(g_objectPrefix + "NewsCountdown",
                                "In: " +
                                FormatNewsCountdown(g_newsState.secondsToEvent));

            UpdateDashboardText(g_objectPrefix + "NewsRule",
                                "Holding: " +
                                GetNewsHoldingRuleText() +
                                " | Affected: " +
                                IntegerToString(g_newsState.affectedPositions));
           }

//--- Update the current news holding condition
   UpdateDashboardText(g_objectPrefix + "NewsStatus",
                       "Status: " +
                       NewsHoldingStatusToString(g_newsState.holdingStatus));

//--- Update the combined guard result
   UpdateDashboardText(g_objectPrefix + "OverallStatus",
                       headerStatus);

   if(g_dailySession.balanceConfirmed)
      UpdateDashboardColor(g_objectPrefix + "OverallStatus",
                           GetGuardStatusColor(guardStatus));
   else
      UpdateDashboardColor(g_objectPrefix + "OverallStatus",
                           clrDarkOrange);

//--- Update the compact status summary
   UpdateDashboardText(g_objectPrefix + "StatusDaily",
                       "Daily DD: " +
                       (g_dailySession.balanceConfirmed ?
                        ComplianceStatusToString(g_dailyDrawdown.status) :
                        "WAITING"));

   UpdateDashboardText(g_objectPrefix + "StatusOverall",
                       "Overall DD: " +
                       ComplianceStatusToString(g_overallDrawdown.status));

   UpdateDashboardText(g_objectPrefix + "StatusTarget",
                       "Target: " +
                       TargetStatusToString(g_profitTarget.status));

   UpdateDashboardText(g_objectPrefix + "StatusNews",
                       "News: " +
                       NewsHoldingStatusToString(g_newsState.holdingStatus));

//--- Present all updated chart objects
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Delete dashboard                                                 |
//+------------------------------------------------------------------+
void DeleteDashboard()
  {
//--- Delete only chart objects created by Prop Firm Guard
   int deletedObjects =
      ObjectsDeleteAll(0,
                       g_objectPrefix);

   if(deletedObjects < 0)
     {
      Print("Prop Firm Guard: Could not delete dashboard objects. Error: ",
            GetLastError());
     }

//--- Refresh the chart after removing the interface
   ChartRedraw();
  }
//+------------------------------------------------------------------+