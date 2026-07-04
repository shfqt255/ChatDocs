from supabase import Client, create_client
from langchain_community.vectorstores import SupabaseVectorStore
from langchain_community.document_loaders import PyPDFLoader, Docx2txtLoader, TextLoader
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_groq import ChatGroq
from langchain_mistralai import ChatMistralAI
from langchain_experimental.text_splitter import SemanticChunker
from operator import itemgetter
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnableLambda, RunnablePassthrough
from typing import List, Optional
from langchain_core.documents import Document
from dotenv import load_dotenv
import os

load_dotenv()

TOP_K = 4

# tracks in-progress/completed background uploads by doc_id, so /upload can
# return immediately and the client can poll status separately instead of
# holding one http request open for the entire ingestion (which is what
# was causing 502s on large documents).
UPLOAD_STATUS: dict[str, dict] = {}

# the embedding model is loaded once, the first time it's needed, and reused
# for every request after that - it is NOT rebuilt on every upload, chat, or
# delete call. reloading bge on every request was the direct cause of the
# repeated memory spikes / OOM crashes seen on railway.
_embeddings_instance: Optional[HuggingFaceEmbeddings] = None


def _create_supabase_client() -> Client:
    return create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SECRET_KEY"))


def _create_embeddings() -> HuggingFaceEmbeddings:
    global _embeddings_instance
    if _embeddings_instance is None:
        _embeddings_instance = HuggingFaceEmbeddings(model_name="BAAI/bge-small-en-v1.5")
    return _embeddings_instance

def _create_vector_store() -> SupabaseVectorStore:
    return SupabaseVectorStore(
        client=_create_supabase_client(),
        embedding=_create_embeddings(),
        table_name="documents",
        query_name="match_documents",
        chunk_size=500,
    )

def _load_file (file_path: str) -> List[Document]:
    ext = os.path.splitext(file_path)[1].lower()
    if ext == ".pdf" :
        loader = PyPDFLoader(file_path)
    elif ext == ".docx":
        loader = Docx2txtLoader(file_path)
    elif ext == ".txt":
        loader = TextLoader(file_path)
    else:
        raise ValueError(f"unsupported file type: {ext}")
    return loader.load()


def _split_documents(docs: List[Document]) -> List[Document]:
    splitter = SemanticChunker(
        embeddings=_create_embeddings(),
    )
    return splitter.split_documents(docs)


def ingest_document(file_path:str, user_id: str, doc_id:str, original_filename: str | None = None)-> int:

    raw_docs= _load_file(file_path)

    for doc in raw_docs:
        doc.metadata["user_id"]= user_id
        doc.metadata["doc_id"]= doc_id
        doc.metadata["filename"]= original_filename or os.path.basename(file_path)

    chunks= _split_documents(raw_docs)
    vector_store= _create_vector_store()
    vector_store.add_documents(chunks)
    return len(chunks)


def ingest_document_background(file_path: str, user_id: str, doc_id: str, original_filename: str | None = None) -> None:
    """
    same work as ingest_document, but runs as a background task and writes
    its outcome into UPLOAD_STATUS instead of returning it - this is what
    lets /upload respond immediately instead of blocking on a large file's
    entire chunking + embedding pass. the caller (app.py) polls
    GET /upload/{doc_id}/status to find out when it's actually done.
    the temp file is cleaned up here, once ingestion actually finishes,
    since the request that created it has already returned by then.
    """
    UPLOAD_STATUS[doc_id] = {"state": "processing", "chunks": None, "error": None}
    try:
        chunks = ingest_document(file_path, user_id=user_id, doc_id=doc_id, original_filename=original_filename)
        UPLOAD_STATUS[doc_id] = {"state": "done", "chunks": chunks, "error": None}
    except Exception as exc:
        UPLOAD_STATUS[doc_id] = {"state": "error", "chunks": None, "error": str(exc)}
    finally:
        try:
            os.remove(file_path)
        except OSError:
            pass



def delete_document(doc_id: str, user_id: str) -> None:
    """
    remove all chunks belonging to a document from supabase.
    """
    client = _create_supabase_client()
    client.table("documents").delete().match({
        "metadata->>doc_id": doc_id,
        "metadata->>user_id": user_id,
    }).execute()


def list_documents(user_id: str) -> List[dict]:
    """
    returns one entry per uploaded document (not per chunk), scoped to the
    requesting user. a document may have many chunk rows in supabase, so
    this groups by doc_id and reports the chunk count alongside each one.
    """
    client = _create_supabase_client()
    response = (
        client.table("documents")
        .select("metadata")
        .eq("metadata->>user_id", user_id)
        .execute()
    )

    grouped: dict[str, dict] = {}
    for row in response.data or []:
        metadata = row.get("metadata") or {}
        doc_id = metadata.get("doc_id")
        if not doc_id:
            continue
        if doc_id not in grouped:
            grouped[doc_id] = {
                "doc_id": doc_id,
                "filename": metadata.get("filename", "unknown"),
                "chunk_count": 0,
            }
        grouped[doc_id]["chunk_count"] += 1

    return list(grouped.values())

def _build_llm_candidates() -> List[tuple]:
    return [
        ("gemini-2.5-flash", ChatGoogleGenerativeAI(
            model="gemini-2.5-flash",
            google_api_key=os.getenv("GOOGLE_API_KEY"),
            temperature=0.2,
            max_output_tokens=1024,
        )),
        ("groq-qwen3-32b", ChatGroq(
            model="qwen/qwen3-32b",
            groq_api_key=os.getenv("GROQ_API_KEY"),
            temperature=0.2,
            max_tokens=1024,
        )),
        ("groq-llama-3.3-70b", ChatGroq(
            model="llama-3.3-70b-versatile",
            groq_api_key=os.getenv("GROQ_API_KEY"),
            temperature=0.2,
            max_tokens=1024,
        )),
        ("mistral-large", ChatMistralAI(
            model="mistral-large-latest",
            mistral_api_key=os.getenv("MISTRAL_API_KEY"),
            temperature=0.2,
            max_tokens=1024,
        )),
    ]

# built once at import time instead of on every question, so we are not
# creating new llm clients on every ping.
LLM_CANDIDATES = _build_llm_candidates()

def format_docs(docs):

    return "\n\n".join(
        doc.page_content
        for doc in docs
    )



PROMPT = ChatPromptTemplate.from_template("""
you are an intelligent ai assistant.

use only the context below to answer the question.

if the answer cannot be found in the context,
say "i couldn't find that information in the uploaded documents."

context:
---------
{context}

question:
---------
{question}
""")

def build_rag_chain(user_id: str, doc_id: str):

    vector_store = _create_vector_store()

    retriever = vector_store.as_retriever(
        search_kwargs={
            "k": TOP_K,
            "filter": {
                "user_id": user_id,
                "doc_id": doc_id,
            },
        }
    )

    chain = (

        RunnablePassthrough()

        .assign(

            docs=itemgetter("question") | retriever,

        )

        .assign(

            context=lambda x: format_docs(
                x["docs"]
            )

        )

        | RunnableLambda(
            _invoke_with_fallback
        )

    )

    return chain

def _is_rate_limit_error(error: Exception) -> bool:

    text = str(error).lower()

    keywords = [
        "429",
        "quota",
        "rate limit",
        "resource exhausted",
        "too many requests",
    ]

    return any(word in text for word in keywords)

def _invoke_with_fallback(data: dict) -> dict:
    """
    receives

    {
        "question": "...",
        "context": "...",
        "docs": [...]
    }
    """

    prompt_value = PROMPT.invoke(
        {
            "question": data["question"],
            "context": data["context"],
        }
    )

    last_error = None

    for provider, llm in LLM_CANDIDATES:

        try:

            response = llm.invoke(prompt_value)

            answer = getattr(response, "content", str(response))

            return {
                "answer": answer,
                "provider": provider,
                "docs": data["docs"],
            }

        except Exception as exc:

            last_error = exc

            if _is_rate_limit_error(exc):
                print(f"{provider} exhausted. trying next provider...")
                continue

            print(f"{provider} failed: {exc}")
            continue

    raise RuntimeError(
        f"all providers failed.\n{last_error}"
    )


def query(chain, question: str) -> dict:
    """
    ask a question against the rag chain.

    returns:
    {
        "answer": "...",
        "provider": "...",
        "sources": [...]
    }
    """

    result = chain.invoke(
        {
            "question": question
        }
    )

    sources = []
    seen = set()

    for doc in result["docs"]:

        key = (
            doc.metadata.get("doc_id"),
            doc.metadata.get("page", 0),
        )

        if key in seen:
            continue

        seen.add(key)

        sources.append(
            {
                "file_name": doc.metadata.get(
                    "filename",
                    "unknown",
                ),
                "doc_id": doc.metadata.get(
                    "doc_id"
                ),
                "page": doc.metadata.get(
                    "page",
                    0,
                ),
                "snippet": doc.page_content[:200],
            }
        )

    return {
        "answer": result["answer"],
        "provider": result["provider"],
        "sources": sources,
    }


def get_or_create_thread(user_id: str, doc_id: str, filename: str) -> str:
    """
    each document has exactly one ongoing conversation per user. returns
    the existing thread id if one exists, otherwise creates one.
    """
    client = _create_supabase_client()
    existing = (
        client.table("chat_threads")
        .select("id")
        .eq("user_id", user_id)
        .eq("doc_id", doc_id)
        .limit(1)
        .execute()
    )
    if existing.data:
        return existing.data[0]["id"]

    created = (
        client.table("chat_threads")
        .insert({"user_id": user_id, "doc_id": doc_id, "filename": filename})
        .execute()
    )
    return created.data[0]["id"]


def save_message(thread_id: str, role: str, content: str, provider: str | None = None, sources: list | None = None) -> None:
    client = _create_supabase_client()
    client.table("chat_messages").insert({
        "thread_id": thread_id,
        "role": role,
        "content": content,
        "provider": provider,
        "sources": sources,
    }).execute()


def get_thread_messages(user_id: str, doc_id: str) -> list[dict]:
    """
    returns every message in this user's conversation for one document,
    oldest first. returns an empty list if no conversation exists yet -
    that's a normal state, not an error.
    """
    client = _create_supabase_client()
    thread = (
        client.table("chat_threads")
        .select("id")
        .eq("user_id", user_id)
        .eq("doc_id", doc_id)
        .limit(1)
        .execute()
    )
    if not thread.data:
        return []

    thread_id = thread.data[0]["id"]
    messages = (
        client.table("chat_messages")
        .select("role, content, provider, sources, created_at")
        .eq("thread_id", thread_id)
        .order("created_at")
        .execute()
    )
    return messages.data or []