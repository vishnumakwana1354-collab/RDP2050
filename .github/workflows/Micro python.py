from fastapi import FastAPI, Request
from pydantic import BaseModel
from typing import List, Optional
import json
import uvicorn

app = FastAPI(title="MT5 AI Microstructure Bridge")

# --- DATA MODELS (Compatible with the MQL5 data format) ---
class Message(BaseModel):
    role: str
    content: str

class AIRequest(BaseModel):
    model: str
    temperature: float
    response_format: Optional[dict] = None
    messages: List[Message]

# --- MAIN ENDPOINT (/analyze) ---
@app.post("/analyze")
async def analyze_market(payload: AIRequest):
    """
    This endpoint receives tick and microstructure data from MT5,
    analyzes the data, and returns a BUY/SELL/WAIT decision.
    """
    
    # 1. Extract JSON data from the "user" message sent by MT5
    user_content = "{}"
    for msg in payload.messages:
        if msg.role == "user":
            user_content = msg.content
            break
            
    try:
        facts = json.loads(user_content)
    except json.JSONDecodeError:
        return {"decision": "WAIT", "confidence": 0.0, "reason": "Invalid JSON format"}

    # 2. Extract market facts
    order_type = facts.get("order_type", "WAIT")
    high_velocity = facts.get("high_velocity", False)
    snapback_pips = facts.get("snapback_pips", 0.0)
    min_snapback = facts.get("min_snapback_pips", 2.0)
    deviation_z = facts.get("deviation_z", 0.0)
    
    mtf = facts.get("mtf", {})
    m1_structure = facts.get("m1_structure", {})

    # 3. AI / DECISION-MAKING ALGORITHM (Can be replaced with an ML model later)
    # This is a simple example of decision logic
    
    confidence = 0.0
    decision = "WAIT"
    reason = ""

    # Evaluate the logic when the EA requests SELL confirmation
    if order_type == "SELL":
        score = 0
        
        # Validate snapback and velocity
        if snapback_pips >= min_snapback and high_velocity:
            score += 0.4

        # Validate extreme deviation (overbought condition)
        if deviation_z > 2.0:
            score += 0.3

        # Validate MTF alignment (at least H1 or M15 must be bearish)
        if mtf.get("h1_down") or mtf.get("m15_down"):
            score += 0.2

        # Validate M1 rejection (long upper wick)
        if m1_structure.get("upper_wick_ratio", 0.0) >= 0.2:
            score += 0.1

        confidence = score
        if confidence >= 0.70:
            decision = "SELL"
            reason = "High velocity drop, MTF align, Z-Score high"
        else:
            reason = f"Score only {confidence:.2f}, lacking momentum"

    # Evaluate the logic when the EA requests BUY confirmation
    elif order_type == "BUY":
        score = 0
        
        # Validate snapback and velocity
        if snapback_pips >= min_snapback and high_velocity:
            score += 0.4

        # Validate extreme deviation (deviation_z is already direction-adjusted in MQL5)
        if deviation_z > 2.0:
            score += 0.3

        # Validate MTF alignment (at least H1 or M15 must be bullish)
        if mtf.get("h1_up") or mtf.get("m15_up"):
            score += 0.2

        # Validate M1 rejection (long lower wick)
        if m1_structure.get("lower_wick_ratio", 0.0) >= 0.2:
            score += 0.1

        confidence = score
        if confidence >= 0.70:
            decision = "BUY"
            reason = "High velocity bounce, MTF align, Z-Score high"
        else:
            reason = f"Score only {confidence:.2f}, lacking momentum"

    # 4. Send the JSON response back to MT5
    return {
        "decision": decision,
        "confidence": round(confidence, 2),
        "reason": reason[:60]  # Limit the reason to a maximum of 60 characters for MT5
    }

if __name__ == "__main__":
    # Start the local server on port 8787, matching the InpAIEndpoint parameter in MQL5
    print("AI Bridge Server is running on http://127.0.0.1:8787")
    uvicorn.run(app, host="127.0.0.1", port=8787)