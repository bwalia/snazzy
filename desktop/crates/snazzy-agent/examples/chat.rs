//! Talks to a real model once, through the same runner the app uses.
//!
//!   cargo run -p snazzy-agent --example chat -- ollama qwen3-coder:30b "Say hello in five words."
//!
//! Anthropic reads the key from the ANTHROPIC_API_KEY environment variable (never printed).

use std::sync::Arc;

use futures_util::StreamExt;
use snazzy_agent::{
    AnthropicProvider, ChatMessage, ConversationRunner, ModelProvider, OllamaProvider, RunnerEvent,
    ToolRegistry,
};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [provider, model, text] = args.as_slice() else {
        eprintln!("usage: chat <ollama|anthropic> <model> <message>");
        std::process::exit(2);
    };
    let provider: Arc<dyn ModelProvider> = if provider == "anthropic" {
        Arc::new(AnthropicProvider::new(std::env::var("ANTHROPIC_API_KEY")?)?)
    } else {
        Arc::new(OllamaProvider::new(
            &std::env::var("OLLAMA_URL").unwrap_or_else(|_| "http://localhost:11434".into()),
        )?)
    };
    let runner = ConversationRunner::new(provider, ToolRegistry::new([]), model.clone());
    let mut stream = runner.run(vec![ChatMessage::user(text.clone())]);
    while let Some(event) = stream.next().await {
        match event? {
            RunnerEvent::TextDelta(d) => print!("{d}"),
            RunnerEvent::Usage(u) => {
                eprintln!("\n[{} in, {} out]", u.input_tokens, u.output_tokens)
            }
            RunnerEvent::NeedsUser(m) => eprintln!("\n[needs user] {m}"),
            _ => {}
        }
    }
    println!();
    Ok(())
}
