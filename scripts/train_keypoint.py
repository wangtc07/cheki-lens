import os
import json
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
from torchvision import models, transforms
from PIL import Image
import coremltools as ct
from tqdm import tqdm

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
DATA_DIR = os.path.join(PROJECT_ROOT, "TestData", "ml_dataset", "images")
LABELS_FILE = os.path.join(PROJECT_ROOT, "TestData", "ml_dataset", "labels.json")
OUTPUT_MODEL_DIR = os.path.join(PROJECT_ROOT, "ChekiLens", "Models")

class ChekiDataset(Dataset):
    def __init__(self, data_dir, labels_file):
        self.data_dir = data_dir
        with open(labels_file, 'r') as f:
            self.data = json.load(f)
            
        # Only ToTensor, which maps [0, 255] to [0.0, 1.0].
        # We do ImageNet normalization inside the model for easier CoreML export.
        self.transform = transforms.ToTensor()
        
    def __len__(self):
        return len(self.data)
        
    def __getitem__(self, idx):
        item = self.data[idx]
        img_path = os.path.join(self.data_dir, item["image"])
        image = Image.open(img_path).convert('RGB')
        
        pts = []
        for p in item["keypoints"]:
            pts.extend(p) # [x1, y1, x2, y2, x3, y3, x4, y4]
            
        return self.transform(image), torch.tensor(pts, dtype=torch.float32)

class ChekiCornerNet(nn.Module):
    def __init__(self):
        super().__init__()
        # MobileNetV2 is extremely fast and lightweight for iOS
        self.backbone = models.mobilenet_v2(weights=models.MobileNet_V2_Weights.DEFAULT)
        # Output 8 coordinates
        self.backbone.classifier[1] = nn.Linear(self.backbone.last_channel, 8)
        
        # ImageNet Norm constants
        self.register_buffer('mean', torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer('std', torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        # x is expected to be [0.0, 1.0] RGB
        x = (x - self.mean) / self.std
        return self.backbone(x)

def main():
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"🔥 使用硬體加速裝置: {device}")
    
    print("📦 載入資料集...")
    dataset = ChekiDataset(DATA_DIR, LABELS_FILE)
    
    train_size = int(0.9 * len(dataset))
    val_size = len(dataset) - train_size
    train_ds, val_ds = torch.utils.data.random_split(dataset, [train_size, val_size])
    
    train_loader = DataLoader(train_ds, batch_size=32, shuffle=True, num_workers=4)
    val_loader = DataLoader(val_ds, batch_size=32, shuffle=False, num_workers=4)
    
    model = ChekiCornerNet().to(device)
    criterion = nn.MSELoss()
    optimizer = optim.Adam(model.parameters(), lr=3e-4)
    
    epochs = 15
    print(f"🚀 開始訓練 (總共 {epochs} Epochs)...")
    
    best_val_loss = float('inf')
    
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        
        # Train
        pbar = tqdm(train_loader, desc=f"Epoch {epoch+1}/{epochs} [Train]")
        for images, targets in pbar:
            images, targets = images.to(device), targets.to(device)
            
            optimizer.zero_grad()
            outputs = model(images)
            loss = criterion(outputs, targets)
            loss.backward()
            optimizer.step()
            
            train_loss += loss.item() * images.size(0)
            pbar.set_postfix({'loss': f"{loss.item():.4f}"})
            
        train_loss /= len(train_ds)
        
        # Validate
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for images, targets in val_loader:
                images, targets = images.to(device), targets.to(device)
                outputs = model(images)
                loss = criterion(outputs, targets)
                val_loss += loss.item() * images.size(0)
        val_loss /= len(val_ds)
        
        print(f"👉 Epoch {epoch+1} 總結 | Train Loss: {train_loss:.5f} | Val Loss: {val_loss:.5f}")
        
    print("\n✅ 訓練完成！開始匯出為 iOS CoreML 格式 (.mlpackage)...")
    
    # Export to CoreML
    model.eval()
    model.to("cpu")
    example_input = torch.rand(1, 3, 256, 256)
    traced_model = torch.jit.trace(model, example_input)
    
    # We define input as ImageType so iOS Vision framework will auto-pass CGImage
    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.ImageType(name="image", shape=example_input.shape, scale=1/255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="corners")],
        minimum_deployment_target=ct.target.iOS17
    )
    
    os.makedirs(OUTPUT_MODEL_DIR, exist_ok=True)
    out_path = os.path.join(OUTPUT_MODEL_DIR, "ChekiCornerNet.mlpackage")
    mlmodel.save(out_path)
    
    print(f"🎉 恭喜！模型已成功匯出至: {out_path}")
    print("接下來只需在 Xcode 中實作 VisionManager 呼叫此模型即可。")

if __name__ == '__main__':
    main()
