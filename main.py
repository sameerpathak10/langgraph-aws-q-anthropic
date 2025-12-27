import json
import os
import logging
import boto3
from typing import TypedDict, Literal, Optional, Dict, Any

from langgraph.graph import StateGraph, END
from langchain_core.messages import HumanMessage
from langchain_aws import ChatBedrock

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ===============================
# AWS Clients
# ===============================
bedrock = boto3.client("bedrock-runtime")
q_client = boto3.client("qbusiness")  # AWS Q Business

# Config (override via env vars)
Q_APP_ID = os.environ.get("Q_APP_ID", "YOUR_Q_APP_ID")
Q_USER_ID = os.environ.get("Q_USER_ID")  # Can be None for anonymous access

# ===============================
# Claude LLM (Decision + Agents)
# ===============================
llm = ChatBedrock(
    model_id="anthropic.claude-3-sonnet-20240229-v1:0",
    client=bedrock,
    model_kwargs={"temperature": 0}
)

# ===============================
# LangGraph State
# ===============================
class AgentState(TypedDict):
    user_input: str
    route: Literal["RAG", "AGENT"]
    response: str

# ===============================
# Decision Node
# ===============================
def decide_route(state: AgentState):
    """
    Claude decides whether query needs:
    - Enterprise knowledge (RAG via AWS Q)
    - Multi-step reasoning / orchestration
    """

    prompt = f"""
    You are a routing agent.

    Decide the best route:
    - RAG: If question needs enterprise documents, policies, FAQs, or knowledge base
    - AGENT: If question needs reasoning, steps, actions, or orchestration

    Respond ONLY with one word: RAG or AGENT

    Question:
    {state['user_input']}
    """

    raw = None
    try:
        raw = llm.invoke([HumanMessage(content=prompt)])
    except Exception as e:
        logger.exception("LLM routing call failed")
        return {"route": "RAG"}

    # Extract content robustly and sanitize
    if hasattr(raw, "content"):
        text = raw.content
    elif isinstance(raw, dict) and "content" in raw:
        text = raw["content"]
    else:
        text = str(raw)

    decision = text.strip().upper().split()[0] if text else "RAG"
    if decision not in ("RAG", "AGENT"):
        logger.warning("Unexpected routing decision '%s', defaulting to RAG", decision)
        decision = "RAG"

    return {"route": decision}

# ===============================
# AWS Q RAG Node
# ===============================
def aws_q_rag(state: AgentState):
    """
    Calls AWS Q Business for enterprise RAG
    """

    if Q_APP_ID == "YOUR_Q_APP_ID":
        logger.error("Q_APP_ID is not configured. Set the Q_APP_ID environment variable.")
        return {"response": "Enterprise search is not configured. Please set Q_APP_ID."}

    try:
        chat_kwargs: Dict[str, Any] = {
            "applicationId": Q_APP_ID,
            "userMessage": state["user_input"],
        }
        if Q_USER_ID:
            chat_kwargs["userId"] = Q_USER_ID
        
        response = q_client.chat_sync(**chat_kwargs)
    except Exception as e:
        logger.exception("Q service call failed")
        return {"response": f"Error calling Q service: {e}"}

    # Parse response defensively
    answer = None
    if isinstance(response, dict):
        for key in ("systemMessage", "message", "response", "content"):
            if key in response and response[key]:
                answer = response[key]
                break
        if answer is None and response.get("messages"):
            first = response["messages"][0]
            if isinstance(first, dict):
                answer = first.get("content") or first.get("message")
    if answer is None:
        answer = json.dumps(response)

    return {"response": answer}

# ===============================
# Multi-Step Agent Node
# ===============================
def agent_orchestration(state: AgentState):
    """
    Claude performs reasoning / orchestration
    """

    prompt = f"""
    You are an autonomous cloud operations agent.

    Solve the task step by step and produce a final answer.

    Task:
    {state['user_input']}
    """

    raw = None
    try:
        raw = llm.invoke([HumanMessage(content=prompt)])
    except Exception as e:
        logger.exception("LLM orchestration call failed")
        return {"response": f"Error from LLM: {e}"}

    if hasattr(raw, "content"):
        result_text = raw.content
    else:
        result_text = str(raw)

    return {"response": result_text}

# ===============================
# Build LangGraph
# ===============================
graph = StateGraph(AgentState)

graph.add_node("decide_route", decide_route)
graph.add_node("aws_q_rag", aws_q_rag)
graph.add_node("agent_orchestration", agent_orchestration)

graph.set_entry_point("decide_route")

graph.add_conditional_edges(
    "decide_route",
    lambda state: state["route"],
    {
        "RAG": "aws_q_rag",
        "AGENT": "agent_orchestration",
    },
)

graph.add_edge("aws_q_rag", END)
graph.add_edge("agent_orchestration", END)

app = graph.compile()

# ===============================
# Lambda Handler
# ===============================
def lambda_handler(event, context):
    user_input = event.get("query") or event.get("q") or (json.loads(event.get("body") or "{}").get("query") if isinstance(event.get("body"), str) else None)

    if not user_input:
        return {"statusCode": 400, "body": json.dumps({"error": "Missing 'query' parameter"})}

    try:
        result = app.invoke({
            "user_input": user_input
        })
    except Exception as e:
        logger.exception("Graph invocation failed")
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}

    return {
        "statusCode": 200,
        "body": json.dumps({
            "route": result.get("route"),
            "answer": result.get("response")
        })
    }

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--query", "-q", help="Query to route")
    args = parser.parse_args()
    if not args.query:
        print("Provide --query")
        exit(1)
    evt = {"query": args.query}
    print(lambda_handler(evt, None)["body"])
