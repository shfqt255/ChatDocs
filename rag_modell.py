from supabase import Client, create_client
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_community.vectorstores import SupabaseVectorStore
from langchain_community.document_loaders import PyPDFLoader, Docx2txtLoader, TextLoader
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_groq import ChatGroq
from langchain_mistralai import ChatMistralAI
from langchain_google_genai import GoogleGenerativeAI
from langchain_experimental.text_splitter import SemanticChunker
from operator import itemgetter
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.runnables import RunnableLambda, RunnablePassthrough
from typing import List
from langchain_core.documents import Document
from dotenv import load_dotenv
import os

load_dotenv()

TOP_K = 4

def _create_supabase_client() -> Client:
    return create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SECRET_KEY"))


def _create_embeddings() -> HuggingFaceEmbeddings:
    return HuggingFaceEmbeddings(model_name="BAAI/bge-m3")

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


def ingest_document(file_path:str, user_id: str, doc_id:str)-> int:

    raw_docs= _load_file(file_path)

    for doc in raw_docs:
        doc.metadata["user_id"]= user_id
        doc.metadata["doc_id"]= doc_id
        doc.metadata["filename"]= os.path.basename(file_path)

    chunks= _split_documents(raw_docs)
    vector_store= _create_vector_store()
    vector_store.add_documents(chunks)
    return len(chunks)



def delete_document(doc_id: str, user_id: str) -> None:
    """
    remove all chunks belonging to a document from supabase.
    """
    client = _create_supabase_client()
    client.table("documents").delete().match({
        "metadata->>doc_id": doc_id,
        "metadata->>user_id": user_id,
    }).execute()

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

def build_rag_chain(user_id: str):

    vector_store = _create_vector_store()

    retriever = vector_store.as_retriever(
        search_kwargs={
            "k": TOP_K,
            "filter": {
                "user_id": user_id,
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