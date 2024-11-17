from fastapi import FastAPI, HTTPException, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
import openai
import os
from dotenv import load_dotenv
from llama_index.core import Settings
from llama_index.llms.azure_openai import AzureOpenAI
from llama_index.agent.openai import OpenAIAgent
from llama_index.embeddings.azure_openai import AzureOpenAIEmbedding
from llama_index.core.evaluation import RelevancyEvaluator
from llama_index.core.tools import ToolMetadata
from llama_index.core.tools.eval_query_engine import EvalQueryEngineTool
from sqlalchemy import create_engine, text
import asyncpg
from llama_index.core import SQLDatabase
from helper_tools import CustomAzureCodeInterpreterToolSpec
from llama_index.core.agent import ReActAgent

from llama_index.core.indices.struct_store.sql_query import SQLTableRetrieverQueryEngine
from llama_index.core.objects import SQLTableNodeMapping, ObjectIndex, SQLTableSchema
from llama_index.core.query_engine import NLSQLTableQueryEngine
from llama_index.core import VectorStoreIndex
from ollama import Client as oclient
from llama_index.llms.ollama import Ollama
from llama_index.embeddings.ollama import OllamaEmbedding

import logging
logging.basicConfig(level=logging.DEBUG)

# use a .env file if we have it
load_dotenv(dotenv_path='.env.dev')

# we absolutely need these settings
OPENAI_ENDPOINT = os.getenv("OPENAI_ENDPOINT")
DATABASE_ENDPOINT = os.getenv("DATABASE_ENDPOINT")
OLLAMA_ENDPOINT = os.getenv("OLLAMA_ENDPOINT")
SESSIONS_ENDPOINT = os.getenv("SESSIONS_ENDPOINT")

# those one we should need but will be replaced by MI (TODO)
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")

# if we don't have a primary model we'll use azure openai
LLM_MODEL_PRIMARY = os.getenv("LLM_MODEL_PRIMARY", "azure_openai")

# these are optional as settings, we'll use the defined defaults otherwise
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")
OPENAI_API_VERSION = os.getenv("OPENAI_API_VERSION", "2024-08-01-preview")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-ada-002")
EMBEDDING_API_VERSION = os.getenv("EMBEDDING_API_VERSION", "2023-05-15")



class InferenceRequest(BaseModel):
    query: str

class InferenceResponse(BaseModel):
    response: str

class ModelRequest(BaseModel):
    omodel_name: str


# TODO: potentially make this async
# connect to ollama and see
# if we have ollama models available
def _prep_models():
    # TODO: make this an env setting
    llm_models = [
        LLM_MODEL_PRIMARY,
        "llama3.1:405b",
        "mixtral:latest",
        "mixtral:8x22b",
        "dolphin-mixtral:latest",
        "sqlcoder:7b",
        "qwen2.5-coder:32b",
        "starcoder2:15b",
        #"deepseek-coder-v2:236b",
        #"duckdb-nsql",
        "sqlcoder:15b"
    ]
    embedding_model = 'bge-large'
    llm_model = None
    try:
        o = oclient(OLLAMA_ENDPOINT)
        ollama_models = o.list()['models']
        logging.info("found the following models at the Ollama endpoint: %s" % ollama_models)
        model_names = [m["name"] for m in ollama_models]
        for model in ollama_models:
            logging.info(f"\033[95m \n === model: {model['name']} ===\n  >  size: {model['size']} \n  >  parameter#: {model['details']['parameter_size']}  \033[0m")

        if not embedding_model in model_names:
            logging.info("Pulling embedding model...")
            o.pull(embedding_model)
            logging.info("....done")

        for tm in llm_models:
            if tm in model_names:
                llm_model = tm
                break
        # if we didn't find any of the models we want we pull the first one
        if not llm_model:
            tm = llm_models[0]
            logging.info(f"Pulling llm model {tm}")
            logging.info("This may take several minutes...")
            o.pull(tm)
            logging.info("....done")
        _setup_models(llm_model, embedding_model)
    except Exception as e:
        # if something fails we just use openai
        logging.error("Failure pulling or determining Ollama models: ", str(e))
        _setup_models()


# setup the embedding and llm models
# use azure openai as stock in case we don't get anything different
def _setup_models(llm_model="azure_openai", embedding_model="ada"):

    logging.critical(f"\033[95m setting up llm model {llm_model} and embedding model {embedding_model} \033[0m")
    llm = embed_model = None
    if llm_model == "azure_openai":
        # Initialize the AzureOpenAI model
        llm = AzureOpenAI(
            deployment_name=OPENAI_MODEL,
            model=OPENAI_MODEL,
            api_key=OPENAI_API_KEY,
            azure_endpoint=OPENAI_ENDPOINT,
            api_version=OPENAI_API_VERSION,
        )
        # Initialize the AzureOpenAIEmbedding model
        embed_model = AzureOpenAIEmbedding(
            model=EMBEDDING_MODEL,
            deployment_name=EMBEDDING_MODEL,
            api_key=OPENAI_API_KEY,
            azure_endpoint=OPENAI_ENDPOINT,
            api_version=EMBEDDING_API_VERSION,
        )
    else:
        llm = Ollama(
            model=llm_model,
            request_timeout=180.0,
            base_url=OLLAMA_ENDPOINT,
            temperature=0.0
        )
        embed_model = OllamaEmbedding(
            model_name=embedding_model,
            request_timeout=180.0,
            base_url=OLLAMA_ENDPOINT,
            temperature=0.0
        )

    logging.critical(f"\033[95m {str(llm.complete('mic check 1 2 3'))}  \033[0m")
    logging.info("model setup complete")
    Settings.llm = llm
    Settings.embed_model = embed_model


_prep_models()
app = FastAPI()

security = HTTPBearer()
TOKEN = "841e085171c01d5591602e6aff1701d8"

"""
def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    if credentials.credentials != TOKEN:
        logging.error("Invalid or missing token")
        # Uncomment the following line to enforce token verification
        # raise HTTPException(status_code=403, detail="Invalid or missing token")
    else:
        logging.info("Token verified")
        return True
"""

# retrieve the schema and sample data from the database
@app.on_event("startup")
async def _assemble_query_engine_seed():
    # Connect to the database
    conn = await asyncpg.connect(DATABASE_ENDPOINT)

    # Get the table names
    table_names = await conn.fetch("SELECT table_name FROM information_schema.tables WHERE table_schema='public'")
    logging.info(f"table_names: {table_names}")

    # Get the column names for each table
    database_schema = {}
    sample_data = {}
    for table in table_names:
        table_name = table["table_name"]
        logging.info(f"fetching schema for table_name: {table_name}")
        database_schema[table_name] = {}
        column_names = await conn.fetch(f"SELECT column_name FROM information_schema.columns WHERE table_name='{table_name}'")
        database_schema[table_name]["schema"] = [column["column_name"] for column in column_names]
        table_description = await conn.fetch(f"SELECT obj_description(relfilenode, 'pg_class') AS table_comment FROM pg_class WHERE relname = '{table_name}' AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');")
        if table_description:
            database_schema[table_name]["description"] = f"\033[95m {table_description[0]['table_comment']} \033[0m"
        else:
            database_schema[table_name]["description"] = "No description available"
        sample_data[table_name] = await conn.fetch(str(text(f'SELECT * FROM "{table_name}" LIMIT 5')))

    # Close the database connection
    await conn.close()
    logging.info(f"database_schema: {database_schema}")
    logging.info(f"sample_data: {sample_data}")

    # Store the data in the application state
    app.state.database_schema = database_schema
    app.state.sample_data = sample_data


def using_openai():
    return isinstance(Settings.llm, AzureOpenAI)


async def check_connection(engine):
    conn = await asyncpg.connect(DATABASE_ENDPOINT)
    try:
        res = await conn.fetch("SELECT 1")
        return f"\033[95m  Connection successful to {DATABASE_ENDPOINT[40:60]}! \033[0m"
    except OperationalError as e:
        return f"Failed to connect to the database: {e}"
    finally:
        await conn.close()


@app.on_event("startup")
async def _setup_query_engine():
    schema = app.state.database_schema
    sample_data = app.state.sample_data
    engine = create_engine(DATABASE_ENDPOINT)
    logging.info(await check_connection(engine))
    sql_database = SQLDatabase(engine, include_tables=schema.keys())

    # build out indexer compatible objects
    table_node_mapping = SQLTableNodeMapping(sql_database)
    
    table_schema_objs = []
    tables = schema.keys()
    for table in tables:
        logging.info(f"table: {table} with description: {schema[table]['description']}")
        table_schema_objs.append((SQLTableSchema(table_name=table, context_str=schema[table]['description'])))

    # just use an in-memory index for now
    obj_index = ObjectIndex.from_objects(
        table_schema_objs,
        table_node_mapping,
        VectorStoreIndex,
    )

    query_engine = None
    #if using_openai():
        # Create the NLSQLTableQueryEngine
    query_engine = NLSQLTableQueryEngine(
        sql_database=sql_database,
        tables=tables,
        database_schema=schema,
        sample_data=sample_data,

    )
    logging.critical(f"\033[95m Query engine ready! \033[0m")
    app.state.query_engine = query_engine


@app.on_event("startup")
def _setup_tools_and_agent():

    evaluator = RelevancyEvaluator()
    """
    image_fetcher_metadata = ToolMetadata(
        name="image-fetcher",
        description=(
            "Use this to fetch an image, write python code to fetch the image from https://www.baseball-reference.com/players/a/{PLAYERID}.shtml. Where PLAYERID is the playerid from the database. Download all the images which have /images/headshots/ as part of their directory location and save them in /data. The tool returns the result, stdout and stderr."
        ),
    )
    """

    #image_fetcher = CustomAzureCodeInterpreterToolSpec(
    #    pool_management_ID is the playerid from the database. Download all the images which have /images/headshots/ as part of their directory location and save them in /data. The tool returns the result, stdout and stderr."

    tools = [
        EvalQueryEngineTool(
            evaluator=evaluator,
            query_engine=app.state.query_engine,
            metadata=ToolMetadata(
                name="historical-baseball-stats",
                #TODO: improve this prompt
                description=(
                    "Provides baseball data on players, teams, batts and many more for the years 1871-2015."
                ),
            ),
        ),
    ]
    #tools.append(image_fetcher)
    agent = None
    if using_openai():
        agent = OpenAIAgent.from_tools(tools, verbose=True)
    else:
        agent = ReActAgent.from_tools(tools=tools, verbose=True)
    app.state.agent = agent


@app.post("/inference", response_model=InferenceResponse, tags=["Inference"])
async def model_inference(request: InferenceRequest):
    agent = app.state.agent
    try:
        # TODO: add inference time and model type to response
        response = await agent.achat(request.query)
        return InferenceResponse(response=response.response)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))



@app.get("/list_models", tags=["Model Control"])
async def list_models():
    try:
        o = oclient(OLLAMA_ENDPOINT)
        ollama_models = o.list()['models']
        model_names = [m["name"] for m in ollama_models]
        return {"models": model_names}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/set_model", tags=["Model Control"])
async def set_model(request: ModelRequest):
    try:
        _setup_models(llm_model=request.omodel_name, embedding_model="bge-large")
        return {"status": "model set successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health", tags=["Health"])
async def health_check():

    db_status = await check_connection(DATABASE_ENDPOINT)
    
    # Get current LLM and embedding model
    llm_model = Settings.llm.__class__.__name__
    embedding_model = Settings.embed_model.__class__.__name__

    # Send a "mic check" to the LLM
    try:
        mic_check = Settings.llm.complete("mic check 1 2 3")
    except Exception as e:
        mic_check = f"LLM mic check failed: {str(e)}"

    return {
        "status": "healthy",
        "database_status": str(db_status),
        "llm_model": str(llm_model),
        "embedding_model": str(embedding_model),
        "llm_mic_check": str(mic_check)
    }