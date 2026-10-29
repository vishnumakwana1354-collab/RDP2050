
//+------------------------------------------------------------------+
//|                           lwGreatestSwingValueBreakoutExpert.mq5 |
//|          Copyright 2026, MetaQuotes Ltd. Developer is Chacha Ian |
//|                          https://www.mql5.com/en/users/chachaian |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd. Developer is Chacha Ian"
#property link      "https://www.mql5.com/en/users/chachaian"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Standard libraries                                               |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Custom enumerations                                              |
//+------------------------------------------------------------------+
enum ENUM_GSV_TRADE_DIRECTION
  {
   GSV_TRADE_LONG_ONLY,
   GSV_TRADE_SHORT_ONLY,
   GSV_TRADE_BOTH
  };

enum ENUM_GSV_STOP_LOSS_MODE
  {
   SL_AT_TODAYS_OPEN,
   SL_AT_TODAYS_EXTREME
  };

enum ENUM_GSV_TAKE_PROFIT_MODE
  {
   TP_FIRST_PROFITABLE_OPEN,
   TP_RISK_REWARD_RATIO
  };

enum ENUM_LOT_SIZE_INPUT_MODE
  {
   MODE_MANUAL,
   MODE_AUTO
  };
  
//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input group "General Settings"
input ulong                    magicNumber              = 254700680002;
input ENUM_TIMEFRAMES          timeframe                = PERIOD_CURRENT;
input int                      maxDeviationPoints       = 20;

input group "Setup Conditions"
input int                      oversoldLookbackBars     = 5;
input int                      overboughtLookbackBars   = 5;

input group "Greatest Swing Value Parameters"
input int                      failureSwingLookbackBars = 4;
input int                      swingSearchLimitBars     = 500;
input double                   breakoutMultiplier      = 1.8;

input group "Trade Direction"
input ENUM_GSV_TRADE_DIRECTION tradeDirection           = GSV_TRADE_BOTH;

input group "Trade and Risk Management"
input ENUM_GSV_STOP_LOSS_MODE  stopLossMode             = SL_AT_TODAYS_EXTREME;
input ENUM_GSV_TAKE_PROFIT_MODE takeProfitMode          = TP_RISK_REWARD_RATIO;
input double                   riskRewardRatio          = 2.0;
input ENUM_LOT_SIZE_INPUT_MODE lotSizeMode              = MODE_AUTO;
input double                   riskPerTradePercent      = 1.0;
input double                   fixedLotSize             = 0.10;

//+------------------------------------------------------------------+
//| Greatest Swing Value breakout setup state                        |
//+------------------------------------------------------------------+
struct SGsvBreakoutState
  {
   bool            hasActiveSetup;        // Indicates whether a setup is active
   bool            longSetupActive;       // Identifies a bullish setup
   bool            shortSetupActive;      // Identifies a bearish setup
   datetime        setupBarTime;          // Opening time of the setup bar
   double          setupBarOpen;          // Open price used for breakout projection
   double          projectedEntryPrice;   // Price level monitored for confirmation
   double          averageSwingValue;     // Average of the qualifying failure swings
   ENUM_ORDER_TYPE orderType;             // Market order associated with the setup
  };
  
//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
CTrade            g_trade;                  // Handles trade operations
SGsvBreakoutState g_gsvState;               // Stores the current breakout setup
datetime          g_lastBarOpenTime = 0;    // Tracks the last processed main-timeframe bar
double            g_m1ClosePrices[];        // Stores the two M1 closes used for crossing detection

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Reject invalid parameter combinations before using them
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   //--- Apply the chart appearance used throughout the project
   if(!ConfigureChartAppearance())
      return(INIT_FAILED);

   //--- Configure the trade object for this Expert Advisor
   g_trade.SetExpertMagicNumber(magicNumber);
   g_trade.SetDeviationInPoints(maxDeviationPoints);
   g_trade.SetAsyncMode(false);

   //--- Use the order filling mode supported by the current symbol
   if(!g_trade.SetTypeFillingBySymbol(_Symbol))
     {
      PrintFormat("Failed to set the filling mode for %s. Error: %d",
                  _Symbol,
                  GetLastError());
      return(INIT_FAILED);
     }

   //--- Store copied M1 prices with the newest value at index zero
   if(!ArraySetAsSeries(g_m1ClosePrices,true))
     {
      Print("Failed to configure the M1 close-price array.");
      return(INIT_FAILED);
     }

   //--- Start without a previously active breakout setup
   g_lastBarOpenTime=0;
   ResetGsvBreakoutState();

   Print("Greatest Swing Value Breakout EA initialized.");
   return(INIT_SUCCEEDED);
  }
  
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintFormat("Program terminated. Reason code: %d",reason);
  }
  
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlTick tick;

   //--- Retrieve the current executable Bid and Ask prices
   if(!SymbolInfoTick(_Symbol,tick))
     {
      PrintFormat("Failed to retrieve the current tick. Error: %d",
                  GetLastError());
      return;
     }

   bool isNewBar=false;

   if(!CheckNewBar(_Symbol,
                   timeframe,
                   g_lastBarOpenTime,
                   isNewBar))
      return;

   //--- Perform setup creation and expiration once per new bar
   if(isNewBar)
     {
      if(!ProcessNewBar())
         return;
     }

   if(HasManagedPosition() || !g_gsvState.hasActiveSetup)
      return;

   if(!GetRecentM1ClosePrices())
      return;

   bool breakoutConfirmed=
      (g_gsvState.longSetupActive &&
       IsCrossOver(g_gsvState.projectedEntryPrice,
                   g_m1ClosePrices)) ||
      (g_gsvState.shortSetupActive &&
       IsCrossUnder(g_gsvState.projectedEntryPrice,
                    g_m1ClosePrices));

   if(!breakoutConfirmed)
      return;

   MqlRates currentBar[];
   ArraySetAsSeries(currentBar,true);

   //--- Retrieve the latest bar extreme at the moment of confirmation
   ResetLastError();
   int copied=CopyRates(_Symbol,timeframe,0,1,currentBar);

   if(copied!=1 ||
      currentBar[0].time!=g_gsvState.setupBarTime)
     {
      PrintFormat("Failed to retrieve the active setup bar. "
                  "Copied: %d, error: %d",
                  copied,
                  GetLastError());
      return;
     }

   double executionPrice=0.0;
   double stopLoss=0.0;
   double takeProfit=0.0;

   if(g_gsvState.orderType==ORDER_TYPE_BUY)
     {
      executionPrice=tick.ask;
      stopLoss=(stopLossMode==SL_AT_TODAYS_OPEN)
               ? g_gsvState.setupBarOpen
               : currentBar[0].low;
     }
   else if(g_gsvState.orderType==ORDER_TYPE_SELL)
     {
      executionPrice=tick.bid;
      stopLoss=(stopLossMode==SL_AT_TODAYS_OPEN)
               ? g_gsvState.setupBarOpen
               : currentBar[0].high;
     }
   else
      return;

   if(!PrepareTradePrices(g_gsvState.orderType,
                          executionPrice,
                          stopLoss,
                          takeProfit))
      return;

   double volume=0.0;

   if(!DetermineTradeVolume(g_gsvState.orderType,
                            executionPrice,
                            stopLoss,
                            volume))
      return;

   //--- Clear the setup only after confirmed market execution
   if(OpenMarketPosition(g_gsvState.orderType,
                         volume,
                         stopLoss,
                         takeProfit))
      ResetGsvBreakoutState();
  }
  
//+------------------------------------------------------------------+
//| Validates the Expert Advisor input parameters                    |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   if(magicNumber==0)
     {
      Print("The magic number must be greater than zero.");
      return(false);
     }

   if(oversoldLookbackBars<1 || overboughtLookbackBars<1)
     {
      Print("The setup lookback values must be greater than zero.");
      return(false);
     }

   if(failureSwingLookbackBars<1)
     {
      Print("The failure-swing lookback must be greater than zero.");
      return(false);
     }

   if(swingSearchLimitBars<failureSwingLookbackBars)
     {
      Print("The swing search limit cannot be smaller than the required number of failure swings.");
      return(false);
     }

   if(breakoutMultiplier<=0.0)
     {
      Print("The breakout multiplier must be greater than zero.");
      return(false);
     }

   if(maxDeviationPoints<0)
     {
      Print("The maximum deviation cannot be negative.");
      return(false);
     }

   if(takeProfitMode==TP_RISK_REWARD_RATIO && riskRewardRatio<=0.0)
     {
      Print("The risk-to-reward ratio must be greater than zero.");
      return(false);
     }

   if(lotSizeMode==MODE_MANUAL && fixedLotSize<=0.0)
     {
      Print("The fixed lot size must be greater than zero.");
      return(false);
     }

   if(lotSizeMode==MODE_AUTO &&
      (riskPerTradePercent<=0.0 || riskPerTradePercent>100.0))
     {
      Print("The risk percentage must be greater than zero and not exceed 100.");
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Configures the chart appearance                                  |
//+------------------------------------------------------------------+
bool ConfigureChartAppearance()
  {
   if(!ChartSetInteger(0,CHART_COLOR_BACKGROUND,clrWhite))
     {
      PrintFormat("Failed to set the chart background. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_SHOW_GRID,false))
     {
      PrintFormat("Failed to hide the chart grid. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_MODE,CHART_CANDLES))
     {
      PrintFormat("Failed to set the chart mode. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_COLOR_FOREGROUND,clrBlack))
     {
      PrintFormat("Failed to set the foreground color. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrSeaGreen))
     {
      PrintFormat("Failed to set the bullish candle color. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrBlack))
     {
      PrintFormat("Failed to set the bearish candle color. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_COLOR_CHART_UP,clrSeaGreen))
     {
      PrintFormat("Failed to set the bullish bar color. Error: %d",
                  GetLastError());
      return(false);
     }

   if(!ChartSetInteger(0,CHART_COLOR_CHART_DOWN,clrBlack))
     {
      PrintFormat("Failed to set the bearish bar color. Error: %d",
                  GetLastError());
      return(false);
     }

   //--- Request an immediate refresh after applying the properties
   ChartRedraw();

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Clears the current Greatest Swing Value breakout setup           |
//+------------------------------------------------------------------+
void ResetGsvBreakoutState()
  {
   ZeroMemory(g_gsvState);

   //--- Keep the enumeration field in a valid default state
   g_gsvState.orderType=ORDER_TYPE_BUY;
  }
  
//+------------------------------------------------------------------+
//| Checks whether a new bar has opened                              |
//+------------------------------------------------------------------+
bool CheckNewBar(const string symbol,
                 const ENUM_TIMEFRAMES tf,
                 datetime &lastBarTime,
                 bool &isNewBar)
  {
   isNewBar=false;

   datetime barTimes[];
   ArraySetAsSeries(barTimes,true);

   //--- Request only the opening time of the current bar
   ResetLastError();
   int copied=CopyTime(symbol,tf,0,1,barTimes);

   if(copied!=1 || barTimes[0]<=0)
     {
      PrintFormat("Failed to retrieve the current bar time for %s. "
                  "Copied: %d, error: %d",
                  symbol,
                  copied,
                  GetLastError());
      return(false);
     }

   //--- No change means the current bar has already been processed
   if(barTimes[0]==lastBarTime)
      return(true);

   lastBarTime=barTimes[0];
   isNewBar=true;

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Evaluates the bullish and bearish setup conditions               |
//+------------------------------------------------------------------+
bool EvaluateSetupConditions(bool &bullishSetup,
                             bool &bearishSetup)
  {
   bullishSetup=false;
   bearishSetup=false;

   int requiredBars=
      MathMax(oversoldLookbackBars,overboughtLookbackBars)+2;

   MqlRates rates[];
   ArraySetAsSeries(rates,true);

   //--- Copy enough bars for both directional comparisons
   ResetLastError();
   int copied=CopyRates(_Symbol,timeframe,0,requiredBars,rates);

   if(copied!=requiredBars)
     {
      PrintFormat("Insufficient data for setup evaluation. "
                  "Requested: %d, copied: %d, error: %d",
                  requiredBars,
                  copied,
                  GetLastError());
      return(false);
     }

   //--- Compare the latest completed close with the configured lookbacks
   bullishSetup=
      rates[1].close<rates[oversoldLookbackBars+1].close;

   bearishSetup=
      rates[1].close>rates[overboughtLookbackBars+1].close;

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Retrieves the M1 closes used for breakout confirmation           |
//+------------------------------------------------------------------+
bool GetRecentM1ClosePrices()
  {
   //--- Request the two values required by the crossing functions
   ResetLastError();
   int copied=CopyClose(_Symbol,
                        PERIOD_M1,
                        0,
                        2,
                        g_m1ClosePrices);

   if(copied!=2 || ArraySize(g_m1ClosePrices)<2)
     {
      PrintFormat("Failed to retrieve the required M1 closes. "
                  "Requested: 2, copied: %d, error: %d",
                  copied,
                  GetLastError());
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Calculates the average failed swing for the requested direction  |
//+------------------------------------------------------------------+
bool CalculateAverageFailureSwing(const ENUM_ORDER_TYPE orderType,
                                  double &averageSwing)
  {
   averageSwing=0.0;

   //--- Confirm that usable history is available
   int availableBars=Bars(_Symbol,timeframe);

   if(availableBars<=1)
     {
      PrintFormat("No usable history is available for %s. Error: %d",
                  _Symbol,
                  GetLastError());
      return(false);
     }

   //--- Restrict the search to the configured historical range
   int barsToCopy=MathMin(swingSearchLimitBars,availableBars-1);

   if(barsToCopy<failureSwingLookbackBars)
     {
      Print("There are not enough completed bars to calculate the failure swing.");
      return(false);
     }

   MqlRates rates[];
   ArraySetAsSeries(rates,true);

   //--- Copy completed bars only; the current bar is excluded
   ResetLastError();
   int copied=CopyRates(_Symbol,timeframe,1,barsToCopy,rates);

   if(copied<=0)
     {
      PrintFormat("Failed to copy bars for the failure-swing calculation. "
                  "Error: %d",
                  GetLastError());
      return(false);
     }

   double totalSwing=0.0;
   int qualifyingBars=0;

   //--- Collect the exact number of failure swings required
   for(int index=0;
       index<copied && qualifyingBars<failureSwingLookbackBars;
       index++)
     {
      if(orderType==ORDER_TYPE_BUY &&
         rates[index].close<rates[index].open)
        {
         double swing=rates[index].high-rates[index].open;

         if(swing>0.0)
           {
            totalSwing+=swing;
            qualifyingBars++;
           }
        }
      else if(orderType==ORDER_TYPE_SELL &&
              rates[index].close>rates[index].open)
        {
         double swing=rates[index].open-rates[index].low;

         if(swing>0.0)
           {
            totalSwing+=swing;
            qualifyingBars++;
           }
        }
     }

   //--- Reject an incomplete sample
   if(qualifyingBars!=failureSwingLookbackBars)
     {
      PrintFormat("Only %d of %d required failure swings were found.",
                  qualifyingBars,
                  failureSwingLookbackBars);
      return(false);
     }

   averageSwing=totalSwing/qualifyingBars;

   if(averageSwing<=0.0)
     {
      Print("The calculated average failure swing is invalid.");
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Initializes a one-bar Greatest Swing Value breakout setup        |
//+------------------------------------------------------------------+
bool InitializeSetup(const ENUM_ORDER_TYPE orderType,
                     const double averageSwing)
  {
   if(averageSwing<=0.0)
     {
      Print("The average failure swing must be greater than zero.");
      return(false);
     }

   MqlRates currentBar[];
   ArraySetAsSeries(currentBar,true);

   //--- Retrieve the current bar used to project the breakout trigger
   ResetLastError();
   int copied=CopyRates(_Symbol,timeframe,0,1,currentBar);

   if(copied!=1 ||
      currentBar[0].time<=0 ||
      currentBar[0].open<=0.0)
     {
      PrintFormat("Failed to retrieve the current setup bar. "
                  "Copied: %d, error: %d",
                  copied,
                  GetLastError());
      return(false);
     }

   double projectedEntryPrice=0.0;

   //--- Project the trigger above or below the current bar open
   if(orderType==ORDER_TYPE_BUY)
     {
      projectedEntryPrice=
         currentBar[0].open+(averageSwing*breakoutMultiplier);
     }
   else if(orderType==ORDER_TYPE_SELL)
     {
      projectedEntryPrice=
         currentBar[0].open-(averageSwing*breakoutMultiplier);
     }
   else
     {
      Print("Unsupported order type while initializing the setup.");
      return(false);
     }

   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   projectedEntryPrice=NormalizeDouble(projectedEntryPrice,digits);

   if(projectedEntryPrice<=0.0)
     {
      Print("The projected breakout price is invalid.");
      return(false);
     }

   //--- Clear any previous values before storing the new setup
   ResetGsvBreakoutState();

   g_gsvState.hasActiveSetup     = true;
   g_gsvState.longSetupActive    = (orderType==ORDER_TYPE_BUY);
   g_gsvState.shortSetupActive   = (orderType==ORDER_TYPE_SELL);
   g_gsvState.setupBarTime       = currentBar[0].time;
   g_gsvState.setupBarOpen       = currentBar[0].open;
   g_gsvState.projectedEntryPrice= projectedEntryPrice;
   g_gsvState.averageSwingValue  = averageSwing;
   g_gsvState.orderType          = orderType;

   PrintFormat("%s setup initialized. Trigger: %s, average swing: %s",
               orderType==ORDER_TYPE_BUY ? "Bullish" : "Bearish",
               DoubleToString(projectedEntryPrice,digits),
               DoubleToString(averageSwing,digits));

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Processes tasks that run once per new bar                        |
//+------------------------------------------------------------------+
bool ProcessNewBar()
  {
   //--- Manage positions that use the first-profitable-open exit
   if(!ManageFirstProfitableOpenExit())
      return(false);

   //--- Any unconfirmed setup expires when its originating bar closes
   ResetGsvBreakoutState();

   //--- Do not create another setup while a managed position is open
   if(HasManagedPosition())
      return(true);

   bool bullishSetup=false;
   bool bearishSetup=false;

   if(!EvaluateSetupConditions(bullishSetup,bearishSetup))
      return(false);

   //--- Create a bullish setup when the directional filter is satisfied
   if((tradeDirection==GSV_TRADE_LONG_ONLY ||
       tradeDirection==GSV_TRADE_BOTH) &&
      bullishSetup)
     {
      double averageBuySwing=0.0;

      if(!CalculateAverageFailureSwing(ORDER_TYPE_BUY,
                                       averageBuySwing))
         return(true);

      return(InitializeSetup(ORDER_TYPE_BUY,averageBuySwing));
     }

   //--- Otherwise evaluate the bearish direction
   if((tradeDirection==GSV_TRADE_SHORT_ONLY ||
       tradeDirection==GSV_TRADE_BOTH) &&
      bearishSetup)
     {
      double averageSellSwing=0.0;

      if(!CalculateAverageFailureSwing(ORDER_TYPE_SELL,
                                       averageSellSwing))
         return(true);

      return(InitializeSetup(ORDER_TYPE_SELL,averageSellSwing));
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Checks whether M1 closes crossed above the projected trigger     |
//+------------------------------------------------------------------+
bool IsCrossOver(const double triggerPrice,
                 const double &closePrices[])
  {
   //--- Two closes are required to confirm the transition
   if(ArraySize(closePrices)<2 || triggerPrice<=0.0)
      return(false);

   return(closePrices[1]<=triggerPrice &&
          closePrices[0]>triggerPrice);
  }

//+------------------------------------------------------------------+
//| Checks whether M1 closes crossed below the projected trigger     |
//+------------------------------------------------------------------+
bool IsCrossUnder(const double triggerPrice,
                  const double &closePrices[])
  {
   //--- Two closes are required to confirm the transition
   if(ArraySize(closePrices)<2 || triggerPrice<=0.0)
      return(false);

   return(closePrices[1]>=triggerPrice &&
          closePrices[0]<triggerPrice);
  }
  
//+------------------------------------------------------------------+
//| Prepares and validates stop-loss and take-profit prices          |
//+------------------------------------------------------------------+
bool PrepareTradePrices(const ENUM_ORDER_TYPE orderType,
                        const double executionPrice,
                        double &stopLoss,
                        double &takeProfit)
  {
   if(executionPrice<=0.0 || stopLoss<=0.0)
     {
      Print("The execution or stop-loss price is invalid.");
      return(false);
     }

   double riskDistance=0.0;

   //--- Validate the stop direction and calculate the buy target
   if(orderType==ORDER_TYPE_BUY)
     {
      riskDistance=executionPrice-stopLoss;

      if(riskDistance<=0.0)
        {
         Print("The buy stop-loss must be below the execution price.");
         return(false);
        }

      if(takeProfitMode==TP_RISK_REWARD_RATIO)
         takeProfit=executionPrice+
                    (riskDistance*riskRewardRatio);
      else
         takeProfit=0.0;
     }
   //--- Validate the stop direction and calculate the sell target
   else if(orderType==ORDER_TYPE_SELL)
     {
      riskDistance=stopLoss-executionPrice;

      if(riskDistance<=0.0)
        {
         Print("The sell stop-loss must be above the execution price.");
         return(false);
        }

      if(takeProfitMode==TP_RISK_REWARD_RATIO)
         takeProfit=executionPrice-
                    (riskDistance*riskRewardRatio);
      else
         takeProfit=0.0;
     }
   else
     {
      Print("Unsupported order type while preparing trade prices.");
      return(false);
     }

   //--- Normalize all submitted prices to the symbol precision
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   stopLoss=NormalizeDouble(stopLoss,digits);

   if(takeProfit>0.0)
      takeProfit=NormalizeDouble(takeProfit,digits);

   return(ValidateStopLevelRequirements(orderType,
                                        executionPrice,
                                        stopLoss,
                                        takeProfit));
  }
  
//+------------------------------------------------------------------+
//| Validates the broker's minimum stop-level requirements           |
//+------------------------------------------------------------------+
bool ValidateStopLevelRequirements(const ENUM_ORDER_TYPE orderType,
                                   const double executionPrice,
                                   const double stopLoss,
                                   const double takeProfit)
  {
   long stopsLevelPoints=0;

   //--- Retrieve the broker-defined minimum distance in points
   if(!SymbolInfoInteger(_Symbol,
                         SYMBOL_TRADE_STOPS_LEVEL,
                         stopsLevelPoints))
     {
      PrintFormat("Failed to retrieve the minimum stop level. "
                  "Error: %d",
                  GetLastError());
      return(false);
     }

   double point=0.0;

   if(!SymbolInfoDouble(_Symbol,SYMBOL_POINT,point) ||
      point<=0.0)
     {
      PrintFormat("Failed to retrieve a valid point value. "
                  "Error: %d",
                  GetLastError());
      return(false);
     }

   double minimumDistance=stopsLevelPoints*point;

   if(orderType==ORDER_TYPE_BUY)
     {
      if((executionPrice-stopLoss)<minimumDistance)
        {
         Print("The buy stop-loss violates the broker's minimum stop-level requirements.");
         return(false);
        }

      if(takeProfit>0.0 &&
         (takeProfit-executionPrice)<minimumDistance)
        {
         Print("The buy take-profit violates the broker's minimum stop-level requirements.");
         return(false);
        }
     }
   else if(orderType==ORDER_TYPE_SELL)
     {
      if((stopLoss-executionPrice)<minimumDistance)
        {
         Print("The sell stop-loss violates the broker's minimum stop-level requirements.");
         return(false);
        }

      if(takeProfit>0.0 &&
         (executionPrice-takeProfit)<minimumDistance)
        {
         Print("The sell take-profit violates the broker's minimum stop-level requirements.");
         return(false);
        }
     }
   else
     {
      Print("Unsupported order type during stop-level validation.");
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Determines the trade volume for the selected sizing mode         |
//+------------------------------------------------------------------+
bool DetermineTradeVolume(const ENUM_ORDER_TYPE orderType,
                          const double entryPrice,
                          const double stopLossPrice,
                          double &volume)
  {
   volume=0.0;

   //--- Manual mode still passes through broker-volume validation
   if(lotSizeMode==MODE_MANUAL)
      return(NormalizeVolume(fixedLotSize,volume));

   //--- Automatic mode derives volume from the configured account risk
   return(CalculatePositionSizeByRisk(orderType,
                                      entryPrice,
                                      stopLossPrice,
                                      volume));
  }
  
//+------------------------------------------------------------------+
//| Calculates position size from the configured account risk        |
//+------------------------------------------------------------------+
bool CalculatePositionSizeByRisk(const ENUM_ORDER_TYPE orderType,
                                 const double entryPrice,
                                 const double stopLossPrice,
                                 double &volume)
  {
   volume=0.0;

   double accountBalance=AccountInfoDouble(ACCOUNT_BALANCE);

   if(accountBalance<=0.0)
     {
      Print("The account balance is unavailable or invalid.");
      return(false);
     }

   //--- Convert the configured percentage into a monetary risk amount
   double amountAtRisk=
      (riskPerTradePercent/100.0)*accountBalance;

   if(amountAtRisk<=0.0)
     {
      Print("The calculated amount at risk is invalid.");
      return(false);
     }

   double lossPerLot=0.0;

   //--- Estimate the stop-loss result for a one-lot position
   ResetLastError();

   if(!OrderCalcProfit(orderType,
                       _Symbol,
                       1.0,
                       entryPrice,
                       stopLossPrice,
                       lossPerLot))
     {
      PrintFormat("OrderCalcProfit failed. Error: %d",
                  GetLastError());
      return(false);
     }

   lossPerLot=MathAbs(lossPerLot);

   if(lossPerLot<=0.0)
     {
      Print("The calculated loss per lot is invalid.");
      return(false);
     }

   double rawVolume=amountAtRisk/lossPerLot;

   return(NormalizeVolume(rawVolume,volume));
  }
  
//+------------------------------------------------------------------+
//| Normalizes volume to the symbol's permitted trading constraints  |
//+------------------------------------------------------------------+
bool NormalizeVolume(const double requestedVolume,
                     double &normalizedVolume)
  {
   normalizedVolume=0.0;

   double minimumVolume=0.0;
   double maximumVolume=0.0;
   double volumeStep=0.0;

   //--- Retrieve the symbol-specific volume limits
   if(!SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN,minimumVolume) ||
      !SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX,maximumVolume) ||
      !SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP,volumeStep))
     {
      PrintFormat("Failed to retrieve the symbol's volume constraints. "
                  "Error: %d",
                  GetLastError());
      return(false);
     }

   if(minimumVolume<=0.0 ||
      maximumVolume<minimumVolume ||
      volumeStep<=0.0)
     {
      Print("The symbol's volume constraints are invalid.");
      return(false);
     }

   //--- Keep the requested value inside the permitted range
   double boundedVolume=
      MathMax(minimumVolume,
              MathMin(maximumVolume,requestedVolume));

   //--- Align the value with the broker-defined volume step
   boundedVolume=
      MathFloor((boundedVolume+1.0e-12)/volumeStep)*volumeStep;

   int volumeDigits=GetVolumeDigits(volumeStep);

   normalizedVolume=
      NormalizeDouble(boundedVolume,volumeDigits);

   if(normalizedVolume<minimumVolume ||
      normalizedVolume>maximumVolume)
     {
      Print("The normalized volume is outside the permitted range.");
      return(false);
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Returns the precision required by the symbol's volume step       |
//+------------------------------------------------------------------+
int GetVolumeDigits(const double volumeStep)
  {
   for(int digits=0;digits<=8;digits++)
     {
      if(MathAbs(NormalizeDouble(volumeStep,digits)-volumeStep)
         <1.0e-12)
         return(digits);
     }

   return(8);
  }
  
//+------------------------------------------------------------------+
//| Checks whether this EA manages a position on the current symbol  |
//+------------------------------------------------------------------+
bool HasManagedPosition()
  {
   for(int index=PositionsTotal()-1;index>=0;index--)
     {
      ulong ticket=PositionGetTicket(index);

      if(ticket==0)
        {
         PrintFormat("PositionGetTicket failed at index %d. Error: %d",
                     index,
                     GetLastError());
         continue;
        }

      //--- Ignore positions that belong to another Expert Advisor
      if(PositionGetInteger(POSITION_MAGIC)!=(long)magicNumber)
         continue;

      //--- Ignore positions opened on another symbol
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      return(true);
     }

   return(false);
  }
  
//+------------------------------------------------------------------+
//| Opens a market position and validates the trade-server result    |
//+------------------------------------------------------------------+
bool OpenMarketPosition(const ENUM_ORDER_TYPE orderType,
                        const double volume,
                        const double stopLoss,
                        const double takeProfit)
  {
   ResetLastError();

   bool requestAccepted=false;

   //--- Submit the appropriate market-order request
   if(orderType==ORDER_TYPE_BUY)
     {
      requestAccepted=
         g_trade.Buy(volume,
                     _Symbol,
                     0.0,
                     stopLoss,
                     takeProfit);
     }
   else if(orderType==ORDER_TYPE_SELL)
     {
      requestAccepted=
         g_trade.Sell(volume,
                      _Symbol,
                      0.0,
                      stopLoss,
                      takeProfit);
     }
   else
     {
      Print("Unsupported order type during market execution.");
      return(false);
     }

   //--- A failed method call means the request was not accepted locally
   if(!requestAccepted)
     {
      PrintFormat("%s request failed. Error: %d, "
                  "retcode: %u, description: %s",
                  orderType==ORDER_TYPE_BUY ? "Buy" : "Sell",
                  GetLastError(),
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return(false);
     }

   //--- Confirm that the trade server actually completed the operation
   if(!IsSuccessfulMarketRetcode(g_trade.ResultRetcode()))
     {
      PrintFormat("%s request was not executed. "
                  "Retcode: %u, description: %s",
                  orderType==ORDER_TYPE_BUY ? "Buy" : "Sell",
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return(false);
     }

   PrintFormat("%s position opened. Deal: %I64u",
               orderType==ORDER_TYPE_BUY ? "Buy" : "Sell",
               g_trade.ResultDeal());

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Returns true for completed market-operation retcodes             |
//+------------------------------------------------------------------+
bool IsSuccessfulMarketRetcode(const uint retcode)
  {
   return(retcode==TRADE_RETCODE_DONE ||
          retcode==TRADE_RETCODE_DONE_PARTIAL);
  }
  
//+------------------------------------------------------------------+
//| Closes a managed position and validates the server response      |
//+------------------------------------------------------------------+
bool CloseManagedPosition(const ulong ticket)
  {
   ResetLastError();

   if(!g_trade.PositionClose(ticket))
     {
      PrintFormat("Position close request failed for ticket %I64u. "
                  "Error: %d, retcode: %u, description: %s",
                  ticket,
                  GetLastError(),
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return(false);
     }

   if(!IsSuccessfulMarketRetcode(g_trade.ResultRetcode()))
     {
      PrintFormat("Position %I64u was not closed. "
                  "Retcode: %u, description: %s",
                  ticket,
                  g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
      return(false);
     }

   PrintFormat("Position %I64u closed successfully.",ticket);

   return(true);
  }
  
//+------------------------------------------------------------------+
//| Closes managed positions at the first profitable bar open        |
//+------------------------------------------------------------------+
bool ManageFirstProfitableOpenExit()
  {
   if(takeProfitMode!=TP_FIRST_PROFITABLE_OPEN)
      return(true);

   MqlRates currentBar[];
   ArraySetAsSeries(currentBar,true);

   //--- Retrieve the current bar open used for the exit decision
   ResetLastError();
   int copied=CopyRates(_Symbol,timeframe,0,1,currentBar);

   if(copied!=1 || currentBar[0].open<=0.0)
     {
      PrintFormat("Failed to retrieve the current bar open. "
                  "Copied: %d, error: %d",
                  copied,
                  GetLastError());
      return(false);
     }

   for(int index=PositionsTotal()-1;index>=0;index--)
     {
      ulong ticket=PositionGetTicket(index);

      if(ticket==0)
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=(long)magicNumber ||
         PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      ENUM_POSITION_TYPE positionType=
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double entryPrice=PositionGetDouble(POSITION_PRICE_OPEN);

      bool profitableOpen=
         (positionType==POSITION_TYPE_BUY &&
          currentBar[0].open>entryPrice) ||
         (positionType==POSITION_TYPE_SELL &&
          currentBar[0].open<entryPrice);

      if(profitableOpen)
         return(CloseManagedPosition(ticket));
     }

   return(true);
  }
  
//+------------------------------------------------------------------+
