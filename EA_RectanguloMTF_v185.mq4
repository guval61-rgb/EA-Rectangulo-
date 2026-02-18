//+------------------------------------------------------------------+
//|                                    EA_RectanguloMTF_V1.8.5.mq4   |
//|                                   Sistema Rectángulo H4-M15-M1   |
//|           V1.8.5 - BE con buffer StopLevel (solución error 130)  |
//+------------------------------------------------------------------+
#property copyright "Guido Valencia"
#property version   "1.85"
#property strict

//--- Parámetros externos
input double LotSize = 0.01;           // Tamaño de lote
input int MagicNumber = 12345;         // Magic Number
input int Slippage = 3;                // Deslizamiento

//--- Períodos de MAs (especificados)
input int MA50_Period = 50;
input int MA55_Period = 55;
input int MA20_Period = 20;
input int MA22_Period = 22;

//--- FILTROS OPTIMIZADOS V1.7 - SESIÓN-ESPECÍFICOS
input double MinWickPips = 2.6;       // NY_AM: Mecha mínima pips
input double MaxWickPips = 3.5;       // NY_AM: Mecha máxima pips  
input bool FilterSessions = true;     // Activar filtros sesión/hora
input int LondonStartGMT = 8;         // London inicio GMT (no usar)
input int LondonEndGMT = 13;          // London fin GMT (no usar)
input int NYAMStartGMT = 13;          // NY_AM inicio GMT
input int NYAMEndGMT = 17;            // NY_AM fin GMT
input bool OnlyHistoricalSR = true;   // Solo SR_Historical + FVG

//--- BREAKEVEN V1.8.2
input bool UseBreakeven = true;       // Activar breakeven
input double BreakevenPips = 0.5;     // Pips profit para activar BE

//--- Variables globales
double PointValue;
int Ticket = -1;
double EntryPrice = 0;
double InitialSL = 0;
double CurrentSL = 0;
bool MovedToBE = false;  // Flag para evitar múltiples llamadas OrderModify

//--- Control de barras
datetime LastBarM15 = 0;
datetime LastBarM1 = 0;
int BrokerGMTOffset = 0;

//--- Logging CSV
int FileHandle = -1;
string LogFileName = "";
string CurrentSignalType = "";  // Tipo de señal: SR_Historical, SR_2ndTouch, FVG, Session

//--- Logging M1 Tracking V1.8.1
int M1FileHandle = -1;
string M1LogFileName = "";
int CurrentTradeNum = 0;
int TickCounter = 0;
double MaxProfitPips = 0;
double MinProfitPips = 0;
bool ReachedBE = false;
bool Reached1R = false;
bool Reached2R = false;
datetime TradeOpenTime = 0;

//--- Estructura para niveles S/R con metadata
struct SRLevel {
   double price;
   int touchCount;
   string touchType;  // "Exact", "CrossAndReturn", "Gap"
   int firstBarIndex;  // Barra donde se detectó primero
};

//--- Caché de niveles y sesiones
struct LevelCache {
   bool valid;
   datetime timestamp;
   double fvgLevels[];
   double sessionHighs[4];  // Daily, Asia, London, NY
   double sessionLows[4];
   SRLevel srLevels[];
};
LevelCache Cache;

//--- Variables de rectángulo
struct Rectangle {
   bool active;
   double triggerLine;    // Cierre de M15
   double slLine;         // Mínimo o Máximo de M15
   int direction;         // 1=Alcista, -1=Bajista
   datetime timeCreated;
   int barsWaitedM1;      // Contador barras M1 esperadas
   string lineName;       // Nombre línea dibujada
};
Rectangle CurrentRect;

//+------------------------------------------------------------------+
//| Inicialización                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   PointValue = Point;
   if(Digits == 3 || Digits == 5) PointValue *= 10;
   
   CurrentRect.active = false;
   CurrentRect.barsWaitedM1 = 0;
   CurrentRect.lineName = "";
   
   LastBarM15 = iTime(Symbol(), PERIOD_M15, 0);
   
   //--- Calcular offset GMT del broker
   datetime serverTime = TimeCurrent();
   datetime gmtTime = TimeGMT();
   BrokerGMTOffset = (int)((serverTime - gmtTime) / 3600);
   
   //--- Inicializar caché
   Cache.valid = false;
   ArrayResize(Cache.fvgLevels, 0);
   ArrayResize(Cache.srLevels, 0);
   
   //--- Crear archivo CSV con nombre ÚNICO automático
   //    Usa GetTickCount() (milisegundos desde inicio Windows) como sufijo único
   //    Formato: RectMTF_v162_EURUSD_20250203_000100_12345678.csv
   
   datetime backtest_start = TimeCurrent(); // Fecha/hora inicio backtest
   uint ticks = GetTickCount(); // Milisegundos del sistema - SIEMPRE único
   
   string version = "v185";
   
   string timestamp = StringFormat("%04d%02d%02d_%02d%02d%02d_%u",
                                    TimeYear(backtest_start), TimeMonth(backtest_start), TimeDay(backtest_start),
                                    TimeHour(backtest_start), TimeMinute(backtest_start), TimeSeconds(backtest_start),
                                    ticks);
   
   LogFileName = "RectMTF_" + version + "_" + Symbol() + "_" + timestamp + ".csv";
   M1LogFileName = "RectMTF_" + version + "_" + Symbol() + "_" + timestamp + "_M1_TRACKING.csv";
   
   FileHandle = FileOpen(LogFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
   M1FileHandle = FileOpen(M1LogFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
   
   if(FileHandle != INVALID_HANDLE) {
      //--- Escribir encabezados principales
      FileWrite(FileHandle, "Timestamp", "Event", "TrendH4", "TrendM15", 
                "ImbalanceCount", "FVGCount", "SRCount", "SessionCount",
                "LevelType", "LevelPrice", "TriggerPrice", "SLPrice", 
                "TradeType", "TradeResult", "Profit", "Balance",
                "WickUpperPips", "WickLowerPips", "BodyPips", "WickToBodyRatio", "RangePips",
                "TouchCount", "TouchType", "BarsSinceLastTouch", "SignalType");
      
      Print("=== CSV CREADO EXITOSAMENTE ===");
      Print("Nombre: ", LogFileName);
      Print("Ubicación: \\MQL4\\Files\\Common\\");
   }
   else {
      Print("ERROR CRÍTICO: No se pudo crear CSV");
      Print("Nombre intentado: ", LogFileName);
   }
   
   if(M1FileHandle != INVALID_HANDLE) {
      //--- Escribir encabezados M1 tracking
      FileWrite(M1FileHandle, "Timestamp", "TradeNum", "TickNum", "Bid", "Ask",
                "CurrentProfitPips", "CurrentR", "MaxProfitPips", "MinProfitPips",
                "ReachedBE", "Reached1R", "Reached2R", "DurationMin");
      
      Print("=== CSV M1 TRACKING CREADO ===");
      Print("Nombre: ", M1LogFileName);
   }
   else {
      Print("ERROR: No se pudo crear CSV M1 Tracking");
   }
   
   Print("=== EA_RectanguloMTF_V1.8.5 Inicializado ===");
   Print("Symbol: ", Symbol(), " | LotSize: ", LotSize);
   Print("Broker GMT Offset: ", BrokerGMTOffset, " horas");
   Print("--- V1.8.5 - BE CON BUFFER STOPLEVEL (SOLUCIÓN ERROR 130) ---");
   Print("London: Solo SR_Historical en 08h y 11h GMT");
   Print("NY_AM: FVG + SR_Historical en 13-17 GMT con mecha 2.6-3.5 pips");
   Print("Breakeven: ", (UseBreakeven ? "ACTIVADO" : "DESACTIVADO"), " con buffer StopLevel para evitar error 130");
   Print("Gestión WR: Conservadora (permite trades >2 horas)");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Desinicialización                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(FileHandle != INVALID_HANDLE) {
      FileClose(FileHandle);
      Print("CSV cerrado: ", LogFileName);
   }
   
   if(M1FileHandle != INVALID_HANDLE) {
      FileClose(M1FileHandle);
      Print("CSV M1 Tracking cerrado: ", M1LogFileName);
   }
   
   Print("=== EA Desactivado ===");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   if(Period() != PERIOD_M1) {
      static bool warned = false;
      if(!warned) {
         Print("ADVERTENCIA: Ejecutar en gráfico M1");
         warned = true;
      }
      return;
   }
   
   //--- Verificar trades cerrados
   CheckClosedTrades();
   
   //--- Detectar nueva barra M15
   datetime currentBarM15 = iTime(Symbol(), PERIOD_M15, 0);
   bool isNewBarM15 = (currentBarM15 != LastBarM15);
   
   //--- Detectar nueva barra M1
   datetime currentBarM1 = iTime(Symbol(), PERIOD_M1, 0);
   bool isNewBarM1 = (currentBarM1 != LastBarM1);
   if(isNewBarM1) LastBarM1 = currentBarM1;
   
   if(isNewBarM15) {
      LastBarM15 = currentBarM15;
      Cache.valid = false;  // Invalidar caché
      
      //--- Verificar timeout de rectángulo
      if(CurrentRect.active) {
         //--- Verificar si segunda vela M15 también muestra debilidad
         int trendH4 = GetTrend(PERIOD_H4);
         int trendM15 = GetTrend(PERIOD_M15);
         
         if(trendH4 != 0 && trendM15 != 0 && trendH4 == trendM15) {
            if(CheckWeaknessM15(trendM15)) {
               Print("Segunda vela M15 con debilidad - Manteniendo rectángulo");
               UpdateRectangle(trendM15);  // Actualizar con nueva vela
            }
            else {
               Print("Timeout rectángulo - Segunda vela sin debilidad");
               CancelRectangle();
            }
         }
         else {
            Print("Timeout rectángulo - Tendencia cambió");
            CancelRectangle();
         }
      }
   }
   
   //--- Gestionar posición abierta
   if(HasOpenPosition()) {
      ManagePosition();
      
      //--- TRACKING M1: Loggear estado actual del trade
      if(M1FileHandle != INVALID_HANDLE && OrderSelect(Ticket, SELECT_BY_TICKET)) {
         TickCounter++;
         
         double currentPrice = (OrderType() == OP_BUY) ? Bid : Ask;
         double slDistance = MathAbs(EntryPrice - InitialSL);
         
         if(slDistance > 0) {
            double profit = (OrderType() == OP_BUY) ? (currentPrice - EntryPrice) : (EntryPrice - currentPrice);
            double profitPips = profit / PointValue;
            double currentR = profit / slDistance;
            
            // Actualizar máximos
            if(profitPips > MaxProfitPips) MaxProfitPips = profitPips;
            if(profitPips < MinProfitPips) MinProfitPips = profitPips;
            
            // Actualizar niveles alcanzados
            if(profitPips >= 0 && !ReachedBE) ReachedBE = true;
            if(currentR >= 1.0 && !Reached1R) Reached1R = true;
            if(currentR >= 2.0 && !Reached2R) Reached2R = true;
            
            // Calcular duración
            double durationMin = (TimeCurrent() - TradeOpenTime) / 60.0;
            
            // Loggear cada 10 ticks para reducir tamaño archivo
            if(TickCounter % 10 == 0 || TickCounter == 1) {
               FileWrite(M1FileHandle, 
                        TimeToString(TimeCurrent()), CurrentTradeNum, TickCounter,
                        Bid, Ask, profitPips, currentR, MaxProfitPips, MinProfitPips,
                        (ReachedBE ? 1 : 0), (Reached1R ? 1 : 0), (Reached2R ? 1 : 0),
                        durationMin);
            }
         }
      }
      
      return;
   }
   
   //--- Buscar nueva oportunidad solo en nueva barra M15
   if(!CurrentRect.active && isNewBarM15) {
      //--- FILTRO: Verificar sesión válida (London o NY_AM)
      if(!IsValidSession()) {
         return;  // Fuera de horario permitido
      }
      
      //--- Verificar tendencia H4 y M15
      int trendH4 = GetTrend(PERIOD_H4);
      int trendM15 = GetTrend(PERIOD_M15);
      
      if(trendH4 == 0 || trendM15 == 0) return;
      if(trendH4 != trendM15) return;
      
      //--- Cachear niveles si es necesario
      if(!Cache.valid) {
         CacheLevels(trendM15);
      }
      
      //--- Buscar debilidad en M15
      if(CheckWeaknessM15(trendM15)) {
         CreateRectangle(trendM15);
      }
   }
   else if(CurrentRect.active && isNewBarM1) {
      //--- Verificar breakout en M1 (máximo 5 barras) - SOLO EN NUEVA BARRA M1
      CurrentRect.barsWaitedM1++;
      
      if(CurrentRect.barsWaitedM1 > 5) {
         Print("Timeout M1 - 5 barras sin breakout");
         CancelRectangle();
      }
      else {
         CheckBreakoutM1();
      }
   }
}

//+------------------------------------------------------------------+
//| Verificar posición abierta                                        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber) {
            Ticket = OrderTicket();
            return true;
         }
      }
   }
   Ticket = -1;
   return false;
}

//+------------------------------------------------------------------+
//| Verificar y registrar trades cerrados                            |
//+------------------------------------------------------------------+
void CheckClosedTrades()
{
   static int lastProcessedIndex = 0;  // Índice del último trade procesado
   
   int totalHistory = OrdersHistoryTotal();
   
   //--- Solo procesar trades nuevos desde último índice
   for(int i = lastProcessedIndex; i < totalHistory; i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      
      //--- Registrar trade cerrado
      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      
      if(FileHandle != INVALID_HANDLE) {
         FileWrite(FileHandle, TimeToString(OrderCloseTime()), "TRADE_CLOSED", 
                   "", "", "", "", "", "",
                   "", "", OrderOpenPrice(), OrderStopLoss(), 
                   (OrderType() == OP_BUY ? "BUY" : "SELL"), 
                   (profit > 0 ? "WIN" : "LOSS"), 
                   DoubleToString(profit, 2), AccountBalance(),
                   "", "", "", "", "",
                   "", "", "", "");
      }
      
      Print("=== TRADE CERRADO ===");
      Print("Ticket: ", OrderTicket());
      Print("Resultado: ", (profit > 0 ? "WIN" : "LOSS"));
      Print("Profit: ", DoubleToString(profit, 2));
   }
   
   //--- Actualizar índice al total actual
   lastProcessedIndex = totalHistory;
}

//+------------------------------------------------------------------+
//| Calcular métricas de mechas de una vela                           |
//+------------------------------------------------------------------+
void CalculateWickMetrics(int timeframe, int bar, double &wickUpper, double &wickLower, 
                          double &body, double &ratio, double &range)
{
   double high = iHigh(Symbol(), timeframe, bar);
   double low = iLow(Symbol(), timeframe, bar);
   double close = iClose(Symbol(), timeframe, bar);
   double open = iOpen(Symbol(), timeframe, bar);
   
   range = (high - low) / PointValue;
   wickUpper = (high - MathMax(open, close)) / PointValue;
   wickLower = (MathMin(open, close) - low) / PointValue;
   body = MathAbs(close - open) / PointValue;
   
   ratio = (body > 0) ? ((wickUpper + wickLower) / body) : 0;
}

//+------------------------------------------------------------------+
//| Detectar tipo de toque en nivel S/R                               |
//+------------------------------------------------------------------+
string GetTouchType(double level, int barIndex, int trend)
{
   double high_i = iHigh(Symbol(), PERIOD_M15, barIndex);
   double low_i = iLow(Symbol(), PERIOD_M15, barIndex);
   double close_i = iClose(Symbol(), PERIOD_M15, barIndex);
   double open_i = iOpen(Symbol(), PERIOD_M15, barIndex);
   
   if(barIndex < 99) {
      double high_prev = iHigh(Symbol(), PERIOD_M15, barIndex + 1);
      double low_prev = iLow(Symbol(), PERIOD_M15, barIndex + 1);
      
      if(trend == 1) {
         //--- Alcista: nivel es soporte
         // CrossAndReturn: Low cruza nivel y cierra arriba
         if(low_i < level && close_i > level) return "CrossAndReturn";
         
         // Exact: Toca nivel sin cruzar, vela anterior no tocaba
         if(MathAbs(low_i - level) < PointValue && low_prev > level + 2*PointValue) 
            return "Exact";
         
         // Gap: Vela anterior cierra abajo, esta abre arriba del nivel
         if(high_prev < level && open_i > level) return "Gap";
      }
      else if(trend == -1) {
         //--- Bajista: nivel es resistencia
         // CrossAndReturn: High cruza nivel y cierra abajo
         if(high_i > level && close_i < level) return "CrossAndReturn";
         
         // Exact: Toca nivel sin cruzar, vela anterior no tocaba
         if(MathAbs(high_i - level) < PointValue && high_prev < level - 2*PointValue) 
            return "Exact";
         
         // Gap: Vela anterior cierra arriba, esta abre abajo del nivel
         if(low_prev > level && open_i < level) return "Gap";
      }
   }
   
   return "Normal";
}

//+------------------------------------------------------------------+
//| Verificar sesión y hora válida - V1.8 OPTIMIZADO                 |
//+------------------------------------------------------------------+
bool IsValidSession()
{
   if(!FilterSessions) return true;  // Filtro desactivado
   
   datetime now = TimeCurrent();
   int hourGMT = TimeHour(now) - BrokerGMTOffset;
   
   // Normalizar hora GMT (0-23)
   if(hourGMT < 0) hourGMT += 24;
   if(hourGMT >= 24) hourGMT -= 24;
   
   // London SOLO horas GANADORAS: 08h, 11h GMT
   // ELIMINA: 10h (-9.17 pips perdedor)
   bool isLondon08 = (hourGMT == 8);
   bool isLondon11 = (hourGMT == 11);
   bool isLondonValid = isLondon08 || isLondon11;
   
   // NY_AM completo: 13-17 GMT  
   bool isNYAM = (hourGMT >= NYAMStartGMT && hourGMT < NYAMEndGMT);
   
   return isLondonValid || isNYAM;
}

//+------------------------------------------------------------------+
//| Obtener tendencia usando MAs                                      |
//+------------------------------------------------------------------+
int GetTrend(int timeframe)
{
   double ma50_close = iMA(Symbol(), timeframe, MA50_Period, 0, MODE_SMA, PRICE_CLOSE, 1);
   double ma55_open = iMA(Symbol(), timeframe, MA55_Period, 0, MODE_SMA, PRICE_OPEN, 1);
   double ma20_close = iMA(Symbol(), timeframe, MA20_Period, 0, MODE_SMA, PRICE_CLOSE, 1);
   double ma22_open = iMA(Symbol(), timeframe, MA22_Period, 0, MODE_SMA, PRICE_OPEN, 1);
   
   //--- Alcista
   if(ma50_close > ma55_open && ma20_close > ma22_open) {
      return 1;
   }
   
   //--- Bajista
   if(ma50_close < ma55_open && ma20_close < ma22_open) {
      return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Verificar debilidad en M15 en nivel relevante                     |
//+------------------------------------------------------------------+
bool CheckWeaknessM15(int trend)
{
   double high1 = iHigh(Symbol(), PERIOD_M15, 1);
   double low1 = iLow(Symbol(), PERIOD_M15, 1);
   double close1 = iClose(Symbol(), PERIOD_M15, 1);
   double open1 = iOpen(Symbol(), PERIOD_M15, 1);
   
   bool debilidadYRechazo = false;
   double nivelTocado = 0;
   double mechaRelevante = 0;
   
   if(trend == 1) {
      //--- ALCISTA: Vela bajista (debilidad) que cierra arriba mínimo (rechazo)
      bool velaContraTendencia = open1 > close1;
      bool rechazoHaciaTendencia = close1 > low1;
      debilidadYRechazo = velaContraTendencia && rechazoHaciaTendencia;
      nivelTocado = low1;
      mechaRelevante = close1 - low1;  // Mecha inferior
   }
   else if(trend == -1) {
      //--- BAJISTA: Vela alcista (debilidad) que cierra abajo máximo (rechazo)
      bool velaContraTendencia = close1 > open1;
      bool rechazoHaciaTendencia = close1 < high1;
      debilidadYRechazo = velaContraTendencia && rechazoHaciaTendencia;
      nivelTocado = high1;
      mechaRelevante = high1 - close1;  // Mecha superior
   }
   
   if(!debilidadYRechazo) return false;
   
   //=== FILTRO MECHA SESIÓN-ESPECÍFICO V1.7 ===
   datetime now = TimeCurrent();
   int hourGMT = TimeHour(now) - BrokerGMTOffset;
   if(hourGMT < 0) hourGMT += 24;
   if(hourGMT >= 24) hourGMT -= 24;
   
   // Identificar sesión
   bool isLondon = (hourGMT == 8 || hourGMT == 10 || hourGMT == 11);
   bool isNYAM = (hourGMT >= 13 && hourGMT < 17);
   
   double mechaPips = mechaRelevante / PointValue;
   
   if(isLondon) {
      // LONDON: SIN filtro de mecha (permite todas las mechas)
      Print("London ", hourGMT, "h - Mecha: ", DoubleToString(mechaPips, 2), " pips (sin filtro)");
   }
   else if(isNYAM) {
      // NY_AM: Filtro mecha 2.6-3.5 pips
      if(mechaPips < MinWickPips) {
         Print("NY_AM - Mecha muy pequeña: ", DoubleToString(mechaPips, 2), " pips (mínimo: ", MinWickPips, ")");
         return false;
      }
      
      if(MaxWickPips > 0 && mechaPips > MaxWickPips) {
         Print("NY_AM - Mecha muy grande: ", DoubleToString(mechaPips, 2), " pips (máximo: ", MaxWickPips, ")");
         return false;
      }
      
      Print("NY_AM - Mecha válida: ", DoubleToString(mechaPips, 2), " pips");
   }
   
   //=== FILTRO: SOLO SR_Historical (ELIMINAR 2ndTouch si está activado) ===
   if(OnlyHistoricalSR) {
      // Solo verificar niveles históricos en caché
      bool atRelevantLevel = IsAtRelevantLevel(nivelTocado, trend);
      
      if(atRelevantLevel) {
         Print("Debilidad+Rechazo en nivel relevante - Mecha: ", DoubleToString(mechaPips, 2), " pips");
         return true;
      }
      
      return false;
   }
   
   //=== ESTRATEGIA LEGACY: 2DO TOQUE (Solo si OnlyHistoricalSR = false) ===
   double nivelPrevio = (trend == 1) ? iLow(Symbol(), PERIOD_M15, 2) : iHigh(Symbol(), PERIOD_M15, 2);
   
   if(MathAbs(nivelTocado - nivelPrevio) < PointValue) {
      double wickUp, wickLow, body, ratio, range;
      CalculateWickMetrics(PERIOD_M15, 1, wickUp, wickLow, body, ratio, range);
      
      CurrentSignalType = "SR_2ndTouch";
      
      if(FileHandle != INVALID_HANDLE) {
         FileWrite(FileHandle, TimeToString(TimeCurrent()), "LEVEL_DETECTED", 
                   GetTrend(PERIOD_H4), trend, "", "", "", "",
                   "SR", nivelTocado, "", "", "", "", "", AccountBalance(),
                   wickUp, wickLow, body, ratio, range,
                   2, "Consecutive", 1, CurrentSignalType);
      }
      
      Print("2do toque consecutivo - Mecha: ", DoubleToString(mechaPips, 2), " pips");
      return true;
   }
   
   //=== NIVELES HISTÓRICOS (fallback) ===
   bool atRelevantLevel = IsAtRelevantLevel(nivelTocado, trend);
   
   if(atRelevantLevel) {
      Print("Nivel relevante histórico - Mecha: ", DoubleToString(mechaPips, 2), " pips");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Cachear todos los niveles relevantes                             |
//+------------------------------------------------------------------+
void CacheLevels(int trend)
{
   ArrayResize(Cache.fvgLevels, 0);
   ArrayResize(Cache.srLevels, 0);
   
   //--- Cachear FVG (3 velas consecutivas con gap)
   for(int i = 3; i < 50; i++) {
      double high_prev = iHigh(Symbol(), PERIOD_M15, i+1);
      double low_prev = iLow(Symbol(), PERIOD_M15, i+1);
      double high_next = iHigh(Symbol(), PERIOD_M15, i-1);
      double low_next = iLow(Symbol(), PERIOD_M15, i-1);
      
      //--- FVG alcista: low vela siguiente > high vela anterior
      if(trend == 1 && low_next > high_prev) {
         int size = ArraySize(Cache.fvgLevels);
         ArrayResize(Cache.fvgLevels, size + 1);
         Cache.fvgLevels[size] = (low_next + high_prev) / 2;
      }
      //--- FVG bajista: high vela siguiente < low vela anterior
      else if(trend == -1 && high_next < low_prev) {
         int size = ArraySize(Cache.fvgLevels);
         ArrayResize(Cache.fvgLevels, size + 1);
         Cache.fvgLevels[size] = (high_next + low_prev) / 2;
      }
   }
   
   //--- CÓDIGO DESACTIVADO V1.6: Sessions eliminados de IsAtRelevantLevel
   //Cache.sessionHighs[0] = iHigh(Symbol(), PERIOD_D1, 1);
   //Cache.sessionLows[0] = iLow(Symbol(), PERIOD_D1, 1);
   //
   //double asiaH = 0, asiaL = 0, londonH = 0, londonL = 0, nyH = 0, nyL = 0;
   //GetSessionHL(0 - BrokerGMTOffset, 9 - BrokerGMTOffset, asiaH, asiaL);
   //GetSessionHL(8 - BrokerGMTOffset, 17 - BrokerGMTOffset, londonH, londonL);
   //GetSessionHL(13 - BrokerGMTOffset, 22 - BrokerGMTOffset, nyH, nyL);
   //
   //Cache.sessionHighs[1] = asiaH;
   //Cache.sessionLows[1] = asiaL;
   //Cache.sessionHighs[2] = londonH;
   //Cache.sessionLows[2] = londonL;
   //Cache.sessionHighs[3] = nyH;
   //Cache.sessionLows[3] = nyL;
   
   //--- Cachear S/R (2+ toques) con metadata completa
   ArrayResize(Cache.srLevels, 0);
   bool visitado[];
   ArrayResize(visitado, 100);
   ArrayInitialize(visitado, false);
   
   for(int i = 1; i < 100; i++) {
      if(visitado[i]) continue;
      
      double level = (trend == -1) ? iHigh(Symbol(), PERIOD_M15, i) : iLow(Symbol(), PERIOD_M15, i);
      
      int touchCount = 1;
      string firstTouchType = GetTouchType(level, i, trend);
      visitado[i] = true;
      
      //--- Buscar otros toques en mismo nivel
      for(int j = i + 1; j < 100; j++) {
         if(visitado[j]) continue;
         
         double compareLevel = (trend == -1) ? iHigh(Symbol(), PERIOD_M15, j) : iLow(Symbol(), PERIOD_M15, j);
         
         if(MathAbs(compareLevel - level) < PointValue) {
            touchCount++;
            visitado[j] = true;
         }
      }
      
      //--- Agregar si 2+ toques
      if(touchCount >= 2) {
         int size = ArraySize(Cache.srLevels);
         ArrayResize(Cache.srLevels, size + 1);
         Cache.srLevels[size].price = level;
         Cache.srLevels[size].touchCount = touchCount;
         Cache.srLevels[size].touchType = firstTouchType;
         Cache.srLevels[size].firstBarIndex = i;
      }
   }
   
   Cache.valid = true;
   Cache.timestamp = TimeCurrent();
   
   //--- Log niveles cacheados (OPTIMIZADO: 0 sessions)
   if(FileHandle != INVALID_HANDLE) {
      FileWrite(FileHandle, TimeToString(TimeCurrent()), "CACHE_LEVELS", 
                GetTrend(PERIOD_H4), trend,
                0, ArraySize(Cache.fvgLevels),
                ArraySize(Cache.srLevels), 0,
                "", "", "", "", "", "", "", AccountBalance(),
                "", "", "", "", "",  // Mechas vacías
                "", "", "", "");  // S/R metadata + SignalType vacías
   }
   
   Print("Niveles cacheados: FVG=", ArraySize(Cache.fvgLevels), 
         " S/R=", ArraySize(Cache.srLevels));
}

//+------------------------------------------------------------------+
//| Cancelar rectángulo y borrar línea temporal                      |
//+------------------------------------------------------------------+
void CancelRectangle()
{
   if(CurrentRect.lineName != "" && ObjectFind(0, CurrentRect.lineName) >= 0) {
      ObjectDelete(0, CurrentRect.lineName);
   }
   
   CurrentRect.active = false;
   CurrentRect.barsWaitedM1 = 0;
   CurrentRect.lineName = "";
}

//+------------------------------------------------------------------+
//| Actualizar rectángulo con nueva vela M15                         |
//+------------------------------------------------------------------+
void UpdateRectangle(int trend)
{
   double close1 = iClose(Symbol(), PERIOD_M15, 1);
   double high1 = iHigh(Symbol(), PERIOD_M15, 1);
   double low1 = iLow(Symbol(), PERIOD_M15, 1);
   
   //--- Borrar línea anterior
   if(CurrentRect.lineName != "" && ObjectFind(0, CurrentRect.lineName) >= 0) {
      ObjectDelete(0, CurrentRect.lineName);
   }
   
   //--- Actualizar valores
   if(trend == 1) {
      CurrentRect.triggerLine = close1;
      CurrentRect.slLine = low1;
   }
   else {
      CurrentRect.triggerLine = close1;
      CurrentRect.slLine = high1;
   }
   
   CurrentRect.barsWaitedM1 = 0;
   
   //--- Dibujar nueva línea
   CurrentRect.lineName = "Trigger_" + TimeToString(TimeCurrent());
   ObjectCreate(0, CurrentRect.lineName, OBJ_HLINE, 0, 0, CurrentRect.triggerLine);
   ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_WIDTH, 2);
   
   Print("Rectángulo actualizado - Nuevo trigger: ", CurrentRect.triggerLine);
}

//+------------------------------------------------------------------+
//| Verificar si precio está en nivel relevante                       |
//+------------------------------------------------------------------+
bool IsAtRelevantLevel(double price, int trend)
{
   //--- Verificar FVG
   for(int i = 0; i < ArraySize(Cache.fvgLevels); i++) {
      if(MathAbs(price - Cache.fvgLevels[i]) < 2 * PointValue) {
         //--- Calcular métricas de mecha vela M15 actual
         double wickUp, wickLow, body, ratio, range;
         CalculateWickMetrics(PERIOD_M15, 1, wickUp, wickLow, body, ratio, range);
         
         CurrentSignalType = "FVG";
         
         //=== FILTRO V1.8: RECHAZAR FVG EN LONDON ===
         datetime now = TimeCurrent();
         int hourGMT = TimeHour(now) - BrokerGMTOffset;
         if(hourGMT < 0) hourGMT += 24;
         if(hourGMT >= 24) hourGMT -= 24;
         
         // London (08h, 11h): Solo SR_Historical, NO FVG
         bool isLondon = (hourGMT == 8 || hourGMT == 11);
         
         if(isLondon) {
            Print("FVG rechazado en London ", hourGMT, "h (solo SR_Historical permitido)");
            CurrentSignalType = "";
            return false;
         }
         
         if(FileHandle != INVALID_HANDLE) {
            FileWrite(FileHandle, TimeToString(TimeCurrent()), "LEVEL_DETECTED", 
                      GetTrend(PERIOD_H4), trend, "", "", "", "",
                      "FVG", Cache.fvgLevels[i], "", "", "", "", "", AccountBalance(),
                      wickUp, wickLow, body, ratio, range,
                      "", "", "", CurrentSignalType);
         }
         Print("Nivel en FVG: ", Cache.fvgLevels[i]);
         return true;
      }
   }
   
   //--- Verificar S/R (Solo SR_Historical)
   for(int i = 0; i < ArraySize(Cache.srLevels); i++) {
      if(MathAbs(price - Cache.srLevels[i].price) < 2 * PointValue) {
         //--- Calcular métricas de mecha vela M15 actual
         double wickUp, wickLow, body, ratio, range;
         CalculateWickMetrics(PERIOD_M15, 1, wickUp, wickLow, body, ratio, range);
         
         //--- CORRECCIÓN: Antigüedad = índice de barra donde se detectó primero
         int barsAge = Cache.srLevels[i].firstBarIndex;
         
         //--- Registrar SignalType
         CurrentSignalType = "SR_Historical";
         
         if(FileHandle != INVALID_HANDLE) {
            FileWrite(FileHandle, TimeToString(TimeCurrent()), "LEVEL_DETECTED", 
                      GetTrend(PERIOD_H4), trend, "", "", "", "",
                      "SR", Cache.srLevels[i].price, "", "", "", "", "", AccountBalance(),
                      wickUp, wickLow, body, ratio, range,
                      Cache.srLevels[i].touchCount, Cache.srLevels[i].touchType, barsAge, CurrentSignalType);
         }
         Print("Nivel S/R: ", Cache.srLevels[i].price, " Toques:", Cache.srLevels[i].touchCount, 
               " Tipo:", Cache.srLevels[i].touchType, " Edad:", barsAge);
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Obtener High/Low de sesión específica                            |
//+------------------------------------------------------------------+
void GetSessionHL(int startHour, int endHour, double &sessionHigh, double &sessionLow)
{
   sessionHigh = 0;
   sessionLow = 0;
   
   //--- Normalizar horas al rango 0-23
   while(startHour < 0) startHour += 24;
   while(endHour < 0) endHour += 24;
   startHour = startHour % 24;
   endHour = endHour % 24;
   
   datetime today = iTime(Symbol(), PERIOD_D1, 0);
   int shift = 0;
   
   while(shift < 100) {
      datetime barTime = iTime(Symbol(), PERIOD_M15, shift);
      if(barTime < today) break;
      
      int barHour = TimeHour(barTime);
      
      bool inSession = false;
      if(startHour < endHour) {
         inSession = (barHour >= startHour && barHour < endHour);
      }
      else {
         inSession = (barHour >= startHour || barHour < endHour);
      }
      
      if(inSession) {
         double high = iHigh(Symbol(), PERIOD_M15, shift);
         double low = iLow(Symbol(), PERIOD_M15, shift);
         
         if(sessionHigh == 0 || high > sessionHigh) sessionHigh = high;
         if(sessionLow == 0 || low < sessionLow) sessionLow = low;
      }
      
      shift++;
   }
}

//+------------------------------------------------------------------+
//| Crear rectángulo                                                  |
//+------------------------------------------------------------------+
void CreateRectangle(int trend)
{
   double close1 = iClose(Symbol(), PERIOD_M15, 1);
   double high1 = iHigh(Symbol(), PERIOD_M15, 1);
   double low1 = iLow(Symbol(), PERIOD_M15, 1);
   
   CurrentRect.active = true;
   CurrentRect.direction = trend;
   CurrentRect.timeCreated = TimeCurrent();
   CurrentRect.barsWaitedM1 = 0;
   
   if(trend == 1) {
      CurrentRect.triggerLine = close1;
      CurrentRect.slLine = low1;
   }
   else {
      CurrentRect.triggerLine = close1;
      CurrentRect.slLine = high1;
   }
   
   //--- Dibujar línea trigger
   CurrentRect.lineName = "Trigger_" + TimeToString(TimeCurrent());
   if(ObjectFind(0, CurrentRect.lineName) >= 0) ObjectDelete(0, CurrentRect.lineName);
   ObjectCreate(0, CurrentRect.lineName, OBJ_HLINE, 0, 0, CurrentRect.triggerLine);
   ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_COLOR, clrYellow);
   ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_WIDTH, 2);
   
   //--- Log rectángulo creado con métricas de mechas
   double wickUp, wickLow, body, ratio, range;
   CalculateWickMetrics(PERIOD_M15, 1, wickUp, wickLow, body, ratio, range);
   
   if(FileHandle != INVALID_HANDLE) {
      FileWrite(FileHandle, TimeToString(TimeCurrent()), "RECTANGLE_CREATED", 
                GetTrend(PERIOD_H4), trend, "", "", "", "",
                "", "", CurrentRect.triggerLine, CurrentRect.slLine, 
                (trend == 1 ? "BUY" : "SELL"), "", "", AccountBalance(),
                wickUp, wickLow, body, ratio, range,
                "", "", "", CurrentSignalType);  // Incluir SignalType
   }
   
   Print("=== RECTÁNGULO CREADO ===");
   Print("Dirección: ", (trend == 1 ? "ALCISTA" : "BAJISTA"));
   Print("Trigger: ", CurrentRect.triggerLine);
   Print("SL: ", CurrentRect.slLine);
   Print("Tamaño: ", DoubleToString(MathAbs(CurrentRect.triggerLine - CurrentRect.slLine)/PointValue, 1), " pips");
}

//+------------------------------------------------------------------+
//| Verificar breakout en M1                                          |
//+------------------------------------------------------------------+
void CheckBreakoutM1()
{
   double close1_M1 = iClose(Symbol(), PERIOD_M1, 1);
   
   //--- ALCISTA: M1 cierra arriba del trigger
   if(CurrentRect.direction == 1 && close1_M1 > CurrentRect.triggerLine) {
      Print("Breakout alcista en M1 - Abriendo BUY");
      
      //--- Hacer línea permanente (verde)
      if(CurrentRect.lineName != "" && ObjectFind(0, CurrentRect.lineName) >= 0) {
         ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_COLOR, clrLime);
         ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_STYLE, STYLE_SOLID);
      }
      
      OpenTrade(OP_BUY);
      CurrentRect.active = false;
      CurrentRect.lineName = "";  // No borrar línea
   }
   
   //--- BAJISTA: M1 cierra abajo del trigger
   if(CurrentRect.direction == -1 && close1_M1 < CurrentRect.triggerLine) {
      Print("Breakout bajista en M1 - Abriendo SELL");
      
      //--- Hacer línea permanente (roja)
      if(CurrentRect.lineName != "" && ObjectFind(0, CurrentRect.lineName) >= 0) {
         ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_COLOR, clrRed);
         ObjectSetInteger(0, CurrentRect.lineName, OBJPROP_STYLE, STYLE_SOLID);
      }
      
      OpenTrade(OP_SELL);
      CurrentRect.active = false;
      CurrentRect.lineName = "";  // No borrar línea
   }
}

//+------------------------------------------------------------------+
//| Abrir operación                                                   |
//+------------------------------------------------------------------+
void OpenTrade(int orderType)
{
   double price = (orderType == OP_BUY) ? Ask : Bid;
   double sl = CurrentRect.slLine;
   
   Ticket = OrderSend(Symbol(), orderType, LotSize, price, Slippage, sl, 0, 
                      "RectMTF", MagicNumber, 0, clrGreen);
   
   if(Ticket > 0) {
      EntryPrice = price;
      InitialSL = sl;
      CurrentSL = sl;
      MovedToBE = false;  // Resetear flag BE
      
      //--- Inicializar tracking M1
      CurrentTradeNum++;
      TickCounter = 0;
      MaxProfitPips = 0;
      MinProfitPips = 0;
      ReachedBE = false;
      Reached1R = false;
      Reached2R = false;
      TradeOpenTime = TimeCurrent();
      
      //--- Log trade abierto
      if(FileHandle != INVALID_HANDLE) {
         FileWrite(FileHandle, TimeToString(TimeCurrent()), "TRADE_OPENED", 
                   "", "", "", "", "", "",
                   "", "", EntryPrice, InitialSL, 
                   (orderType == OP_BUY ? "BUY" : "SELL"), 
                   "OPENED", "0.00", AccountBalance(),
                   "", "", "", "", "",  // Mechas vacías
                   "", "", "", CurrentSignalType);  // SignalType del rectángulo
      }
      
      Print("=== TRADE ABIERTO ===");
      Print("Ticket: ", Ticket);
      Print("Tipo: ", (orderType == OP_BUY ? "BUY" : "SELL"));
      Print("Precio: ", price);
      Print("SL: ", sl, " (", DoubleToString(MathAbs(price - sl)/PointValue, 1), " pips)");
   }
   else {
      Print("Error abriendo trade: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Gestionar posición según tabla WR                                 |
//+------------------------------------------------------------------+
void ManagePosition()
{
   if(!OrderSelect(Ticket, SELECT_BY_TICKET)) return;
   
   double currentPrice = (OrderType() == OP_BUY) ? Bid : Ask;
   double slDistance = MathAbs(EntryPrice - InitialSL);
   
   if(slDistance == 0) return;
   
   double profit = (OrderType() == OP_BUY) ? (currentPrice - EntryPrice) : (EntryPrice - currentPrice);
   double profitPips = profit / PointValue;
   double wr = profit / slDistance;
   
   //=== BREAKEVEN V1.8.5 - CON BUFFER STOPLEVEL ===
   // Solución error 130: Respetar distancia mínima StopLevel del broker
   if(UseBreakeven && !MovedToBE && profitPips > 0) {
      // Obtener StopLevel del broker (distancia mínima SL-precio)
      int stopLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
      if(stopLevel < 3) stopLevel = 3;  // Mínimo 3 pips si broker no informa
      
      // Buffer = StopLevel + 1 pip extra para seguridad
      double bufferPips = stopLevel + 1.0;
      double bufferPrice = bufferPips * PointValue;
      
      // Calcular SL breakeven con spread + buffer
      double spread = Ask - Bid;
      double breakEvenSL = 0;
      
      if(OrderType() == OP_BUY) {
         // Para BUY: SL = Entry + spread + buffer
         // Esto garantiza distancia mínima respecto al precio actual
         breakEvenSL = EntryPrice + spread + bufferPrice;
      }
      else {
         // Para SELL: SL = Entry - spread - buffer
         breakEvenSL = EntryPrice - spread - bufferPrice;
      }
      
      // Normalizar precio
      breakEvenSL = NormalizeDouble(breakEvenSL, Digits);
      
      // Verificar que SL esté suficientemente lejos del precio actual
      double slDistance_current = MathAbs(breakEvenSL - currentPrice) / PointValue;
      
      if(slDistance_current >= stopLevel) {
         if(OrderModify(Ticket, EntryPrice, breakEvenSL, 0, 0, clrYellow)) {
            Print("=== BREAKEVEN ACTIVADO ===");
            Print("Profit: ", DoubleToString(profitPips, 2), " pips | Buffer: ", DoubleToString(bufferPips, 1), " pips");
            Print("SL: ", breakEvenSL, " (dist actual: ", DoubleToString(slDistance_current, 1), " pips)");
            CurrentSL = breakEvenSL;
            MovedToBE = true;
         }
         else {
            int error = GetLastError();
            if(error != 1) {  // Ignorar error 1 (no error)
               Print("OrderModify error ", error);
            }
         }
      }
   }
   
   //--- Tabla de gestión WR → nuevo SL (OPTIMIZADA V1.6 - Menos agresiva)
   // Permitir trades correr >2 horas (mejor WR: 51.8%)
   double newSL = 0;
   bool shouldMove = false;
   
   if(wr >= 15.0) {
      newSL = (OrderType() == OP_BUY) ? EntryPrice + (12.0 * slDistance) : EntryPrice - (12.0 * slDistance);
      shouldMove = true;
   }
   else if(wr >= 12.0) {
      newSL = (OrderType() == OP_BUY) ? EntryPrice + (9.0 * slDistance) : EntryPrice - (9.0 * slDistance);
      shouldMove = true;
   }
   else if(wr >= 10.0) {
      newSL = (OrderType() == OP_BUY) ? EntryPrice + (7.0 * slDistance) : EntryPrice - (7.0 * slDistance);
      shouldMove = true;
   }
   // ELIMINADO: Movimientos agresivos WR 3-9 que cerraban trades prematuramente
   
   //--- Mover SL si corresponde y es mejor que el actual
   if(shouldMove) {
      bool isBetter = false;
      if(OrderType() == OP_BUY) {
         isBetter = newSL > CurrentSL;
      }
      else {
         isBetter = newSL < CurrentSL;
      }
      
      if(isBetter) {
         if(OrderModify(Ticket, EntryPrice, newSL, 0, 0, clrBlue)) {
            Print("SL movido a ", DoubleToString(wr, 1), "R → nuevo SL: ", newSL);
            CurrentSL = newSL;
         }
      }
   }
}

//+------------------------------------------------------------------+
